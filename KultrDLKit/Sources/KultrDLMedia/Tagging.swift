import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import KultrDLCore
import UniformTypeIdentifiers

/** iTunes-style tags for M4A files (AAC and ALAC). */
enum MP4Tags {
    static func items(_ tags: TrackTags) -> [AVMetadataItem] {
        var out: [AVMetadataItem] = []
        func add(_ key: AVMetadataKey, _ value: (NSCopying & NSObjectProtocol)?, dataType: CFString? = nil) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.keySpace = .iTunes
            item.key = key.rawValue as NSString
            item.value = value
            if let dataType { item.dataType = dataType as String }
            out.append(item)
        }
        func text(_ key: AVMetadataKey, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            add(key, value as NSString)
        }
        text(.iTunesMetadataKeySongName, tags.title)
        text(.iTunesMetadataKeyArtist, tags.artist)
        text(.iTunesMetadataKeyAlbum, tags.album)
        text(.iTunesMetadataKeyAlbumArtist, tags.albumArtist)
        text(.iTunesMetadataKeyReleaseDate, tags.year.map(String.init))
        text(.iTunesMetadataKeyUserGenre, tags.genre)
        text(.iTunesMetadataKeyISRC, tags.isrc)
        if let n = tags.trackNumber {
            add(.iTunesMetadataKeyTrackNumber, Data([0, 0, UInt8((n >> 8) & 0xff), UInt8(n & 0xff), 0, 0, 0, 0]) as NSData)
        }
        if let n = tags.discNumber {
            add(.iTunesMetadataKeyDiscNumber, Data([0, 0, UInt8((n >> 8) & 0xff), UInt8(n & 0xff), 0, 0]) as NSData)
        }
        if let cover = tags.cover {
            let png = ID3.mimeType(cover) == "image/png"
            add(.iTunesMetadataKeyCoverArt, cover as NSData, dataType: png ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG)
        }
        return out
    }

    /** Copies an M4A's audio as it is into a new file with these tags (AAC "original"). */
    static func remux(_ source: URL, to output: URL, tags: TrackTags) async throws {
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw KultrError("The M4A can't be copied.")
        }
        session.outputURL = output
        session.outputFileType = .m4a
        session.metadata = items(tags)
        await session.export()
        guard session.status == .completed else {
            throw session.error ?? KultrError("Copying the M4A failed.")
        }
    }
}

/** Cover art as it goes into files: square JPEG, at most 1200 pixels. */
public enum CoverArt {
    /** Video thumbnails are 16:9 with the art in the middle; everything else just gets smaller if it is huge. */
    public static func squareJPEG(_ data: Data, max: Int = 1200) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: crop) else { return nil }
        let target = min(side, max)
        guard let context = CGContext(
            data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /** Pixel size of an image, or zero. */
    static func size(_ data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        return ((props[kCGImagePropertyPixelWidth] as? Int) ?? 0, (props[kCGImagePropertyPixelHeight] as? Int) ?? 0)
    }
}
