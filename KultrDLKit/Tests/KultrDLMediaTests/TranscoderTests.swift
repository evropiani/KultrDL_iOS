import AVFoundation
import XCTest
import KultrDLCore
@testable import KultrDLMedia

/** Every output format from a two-second test tone, read back to check it is a real file. */
final class TranscoderTests: XCTestCase {
    private var directory: URL!
    private var source: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kdl-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("tone.wav")
        let writer = try WAVWriter(url: source, sampleRate: 44100, channels: 2, bits: 16, tags: TrackTags(title: "Tone", artist: "Test"))
        var samples = [Float](repeating: 0, count: 44100 * 2 * 2)
        for i in 0..<(44100 * 2) {
            let v = Float(sin(2 * Double.pi * 440 * Double(i) / 44100)) * 0.5
            samples[i * 2] = v
            samples[i * 2 + 1] = v
        }
        try samples.withUnsafeBufferPointer { try writer.write($0) }
        try writer.finish()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var tags: TrackTags {
        TrackTags(title: "Paper Boats", artist: "Some Band", album: "Harbour", year: 2012, trackNumber: 3, cover: CoverArt.squareJPEG(Self.png) )
    }

    /** A 4×2 red PNG, to check cover handling (cropped to a square JPEG). */
    static let png: Data = {
        let ctx = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }()

    private func convert(_ format: AudioFormat, _ quality: Quality) async throws -> URL {
        let out = directory.appendingPathComponent("\(format.rawValue)-\(quality.rawValue)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try await Transcoder.convert(
            source: source, container: "wav", preset: DownloadPreset(format: format, quality: quality),
            tags: tags, directory: out, progress: { _ in }
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: result.file.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 1000, "\(format) \(quality)")
        return result.file
    }

    private func assertPlayable(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2.0, accuracy: 0.15, url.lastPathComponent, file: file, line: line)
        let metadata = try await asset.load(.metadata)
        XCTAssertFalse(metadata.isEmpty, "no tags in \(url.lastPathComponent)", file: file, line: line)
    }

    func testCoverIsSquare() throws {
        let jpeg = try XCTUnwrap(CoverArt.squareJPEG(Self.png))
        let size = CoverArt.size(jpeg)
        XCTAssertEqual(size.width, 2)
        XCTAssertEqual(size.height, 2)
    }

    func testMP3() async throws {
        let cbr = try await convert(.mp3, .k320)
        try await assertPlayable(cbr)
        let head = [UInt8](try Data(contentsOf: cbr).prefix(4))
        XCTAssertEqual(head, [0x49, 0x44, 0x33, 0x04])
        try await assertPlayable(try await convert(.mp3, .v0))
    }

    func testFLAC() async throws {
        let f16 = try await convert(.flac, .bit16)
        XCTAssertEqual([UInt8](try Data(contentsOf: f16).prefix(4)), Array("fLaC".utf8))
        try await assertPlayable(f16)
        _ = try await convert(.flac, .bit24)
    }

    func testM4A() async throws {
        try await assertPlayable(try await convert(.aac, .k256))
        try await assertPlayable(try await convert(.alac, .bit24))
    }

    func testWAV() async throws {
        let wav = try await convert(.wav, .bit24)
        let asset = AVURLAsset(url: wav)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2.0, accuracy: 0.05)
    }

    func testOggFormats() async throws {
        let opus = try Data(contentsOf: try await convert(.opus, .k128))
        XCTAssertEqual([UInt8](opus.prefix(4)), Array("OggS".utf8))
        XCTAssertNotNil(opus.range(of: Data("OpusHead".utf8)))
        XCTAssertNotNil(opus.range(of: Data("TITLE=Paper Boats".utf8)))
        let vorbis = try Data(contentsOf: try await convert(.vorbis, .k192))
        XCTAssertEqual([UInt8](vorbis.prefix(4)), Array("OggS".utf8))
        XCTAssertNotNil(vorbis.range(of: Data("vorbis".utf8)))
        XCTAssertNotNil(vorbis.range(of: Data("ARTIST=Some Band".utf8)))
    }

    func testAACFromAnM4A() async throws {
        // AAC "original" from an M4A copies the audio and only rewrites the tags.
        let m4a = try await convert(.aac, .k128)
        let out = directory.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try await Transcoder.convert(
            source: m4a, container: "m4a", preset: DownloadPreset(format: .aac, quality: .original),
            tags: tags, directory: out, progress: { _ in }
        )
        try await assertPlayable(result.file)
    }
}
