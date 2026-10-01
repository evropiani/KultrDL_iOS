import CoreImage
import KultrDLCore
import ImageIO
import SwiftUI
import UIKit

/**
 * Artwork: downloaded once (the URLs are stable, so the disk cache keeps
 * hitting even offline), decoded at the size it is shown, and kept in memory.
 */
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    /** Adds a login to addresses that need one (Navidrome covers); the cache keys stay the plain address. */
    var sign: (@Sendable (URL) -> URL)?

    private init() {
        memory.totalCostLimit = 96 * 1024 * 1024
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("artwork", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024, directory: directory)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    private func key(_ url: URL, _ pixelSize: Int) -> NSString {
        "\(pixelSize)|\(url.absoluteString)" as NSString
    }

    func cached(_ url: URL, pixelSize: Int) -> UIImage? {
        memory.object(forKey: key(url, pixelSize))
    }

    func image(_ url: URL, pixelSize: Int) async -> UIImage? {
        if let hit = cached(url, pixelSize: pixelSize) { return hit }
        guard let result = try? await session.data(from: sign?(url) ?? url) else { return nil }
        if let http = result.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard let image = Self.downsample(result.0, pixelSize: pixelSize) else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(image, forKey: key(url, pixelSize), cost: cost)
        return image
    }

    static func downsample(_ data: Data, pixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, pixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private let blurContext = CIContext(options: [.cacheIntermediates: false])

    /**
     * A small, heavily blurred copy of the artwork, made once and cached, for
     * the background behind the pages. Drawing a ready-blurred image costs
     * nothing per frame, unlike blurring a live one while the page scrolls.
     */
    func blurred(_ url: URL) async -> UIImage? {
        let cacheKey = "blur|\(url.absoluteString)" as NSString
        if let hit = memory.object(forKey: cacheKey) { return hit }
        guard let source = await image(url, pixelSize: 96), let cg = source.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(9.0, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let rendered = blurContext.createCGImage(output, from: input.extent)
        else { return nil }
        let image = UIImage(cgImage: rendered)
        memory.setObject(image, forKey: cacheKey, cost: rendered.width * rendered.height * 4)
        return image
    }

    func cachedBlur(_ url: URL) -> UIImage? {
        memory.object(forKey: "blur|\(url.absoluteString)" as NSString)
    }

    /** The accent colour taken from an image, as ARGB. */
    func dominantColor(_ url: URL) async -> UInt32? {
        guard let image = await image(url, pixelSize: 48), let cg = image.cgImage else { return nil }
        return await Task.detached(priority: .utility) { Self.dominant(cg) }.value
    }

    private static func dominant(_ image: CGImage) -> UInt32? {
        let width = min(64, image.width)
        let height = min(64, image.height)
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var pixels = [UInt32](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = UInt32(bytes[i * 4])
            let g = UInt32(bytes[i * 4 + 1])
            let b = UInt32(bytes[i * 4 + 2])
            let a = UInt32(bytes[i * 4 + 3])
            pixels[i] = a << 24 | r << 16 | g << 8 | b
        }
        return ArtworkColor.dominant(pixels)
    }
}

/** An image from the network, shown once loaded; nothing (so the placeholder shows) until then. */
struct RemoteImage: View {
    let url: URL?
    let pixelSize: Int
    @State private var loaded: UIImage?
    @State private var loadedFor: URL?

    var body: some View {
        let image = loadedFor == url ? loaded : url.flatMap { ImageLoader.shared.cached($0, pixelSize: pixelSize) }
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else {
                loaded = nil
                loadedFor = nil
                return
            }
            let image = await ImageLoader.shared.image(url, pixelSize: pixelSize)
            withAnimation(.easeOut(duration: 0.2)) {
                loaded = image
                loadedFor = url
            }
        }
    }
}
