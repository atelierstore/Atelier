import ImageIO
import SwiftUI
import UIKit

/// Icons, screenshots and news images, downloaded once and kept (#14).
///
/// Downloads go through a larger `URLCache` that prefers what it has on
/// disk, so images show offline and don't download again on every launch.
/// Decoded images are scaled down to the size they're shown at and kept in
/// memory, so long lists don't decode full-size images while scrolling.
@MainActor
final class ImagePipeline {
	static let shared = ImagePipeline()

	private let memory = NSCache<NSString, UIImage>()
	private var inFlight: [NSString: Task<UIImage?, Never>] = [:]
	private let session: URLSession

	private init() {
		memory.totalCostLimit = 96 * 1024 * 1024
		let configuration = URLSessionConfiguration.default
		configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
		configuration.requestCachePolicy = .returnCacheDataElseLoad
		session = URLSession(configuration: configuration)
	}

	private static func key(_ url: URL, _ maxPixels: Int, _ minimumPixels: Int) -> NSString {
		"\(maxPixels)|\(minimumPixels)|\(url.absoluteString)" as NSString
	}

	func cached(_ url: URL, maxPixels: Int, minimumPixels: Int = 0) -> UIImage? {
		memory.object(forKey: Self.key(url, maxPixels, minimumPixels))
	}

	/// Nil when the image can't be loaded, or when its longer side is under
	/// `minimumPixels`: some sources list the 120-pixel app icon as a
	/// screenshot.
	func image(_ url: URL, maxPixels: Int, minimumPixels: Int = 0) async -> UIImage? {
		let key = Self.key(url, maxPixels, minimumPixels)
		if let image = memory.object(forKey: key) { return image }
		if let task = inFlight[key] { return await task.value }
		let session = session
		let task = Task.detached(priority: .utility) { () -> UIImage? in
			guard let data = await Self.data(at: url, session: session) else { return nil }
			return Self.downsample(data, maxPixels: maxPixels, minimumPixels: minimumPixels)
		}
		inFlight[key] = task
		let image = await task.value
		inFlight[key] = nil
		if let image {
			let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
			memory.setObject(image, forKey: key, cost: cost)
		}
		return image
	}

	/// What's at `url`, from the cache or downloaded. An image kept in a
	/// private GitHub repo, which raw.githubusercontent.com answers 404 for,
	/// is read through a GitHub account that can see the repo, as its source
	/// is (#24), and kept as if it had downloaded. A file of Atelier's own,
	/// such as an installed app's icon (#118), is read as it is.
	nonisolated private static func data(at url: URL, session: URLSession) async -> Data? {
		if url.isFileURL { return try? Data(contentsOf: url) }
		guard let (data, response) = try? await session.data(from: url) else { return nil }
		guard (response as? HTTPURLResponse)?.statusCode == 404 else { return data }
		guard let file = await GitHubAccess.privateFile(at: url) else { return nil }
		if let found = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) {
			session.configuration.urlCache?.storeCachedResponse(CachedURLResponse(response: found, data: file), for: URLRequest(url: url))
		}
		return file
	}

	nonisolated private static func downsample(_ data: Data, maxPixels: Int, minimumPixels: Int) -> UIImage? {
		guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
		if minimumPixels > 0 {
			let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
			let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
			let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
			guard max(width, height) >= minimumPixels else { return nil }
		}
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,
			kCGImageSourceThumbnailMaxPixelSize: maxPixels,
		]
		if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
			return UIImage(cgImage: image)
		}
		// When ImageIO makes no smaller copy, the whole image is drawn
		// smaller instead.
		guard let full = UIImage(data: data, scale: 1), full.size.width > 0, full.size.height > 0 else { return nil }
		let scale = min(1, CGFloat(maxPixels) / max(full.size.width, full.size.height))
		let size = CGSize(width: (full.size.width * scale).rounded(), height: (full.size.height * scale).rounded())
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		return UIGraphicsImageRenderer(size: size, format: format).image { _ in
			full.draw(in: CGRect(origin: .zero, size: size))
		}
	}
}

/// An image from `ImagePipeline`, sized to fit `maxPoints` on its longer
/// side, with `placeholder` until it arrives or when it can't be loaded.
struct CachedImage<Placeholder: View>: View {
	let url: URL?
	let maxPoints: CGFloat
	/// Images smaller than this on their longer side show the placeholder.
	var minimumPixels = 0
	@ViewBuilder var placeholder: () -> Placeholder

	var body: some View {
		LoadedImage(url: url, maxPoints: maxPoints, minimumPixels: minimumPixels) { image in
			Image(uiImage: image)
				.resizable()
		} placeholder: {
			placeholder()
		}
	}
}

/// An image from `ImagePipeline` handed to `content` once it's loaded, for
/// views that lay an image out by its shape (#84), with `placeholder` until
/// it arrives or when it can't be loaded. Its size is in pixels: the
/// pipeline decodes at a scale of 1, and never above the image's own size.
struct LoadedImage<Content: View, Placeholder: View>: View {
	let url: URL?
	let maxPoints: CGFloat
	/// Images smaller than this on their longer side show the placeholder.
	var minimumPixels = 0
	@ViewBuilder var content: (UIImage) -> Content
	@ViewBuilder var placeholder: () -> Placeholder

	@Environment(\.displayScale) private var displayScale
	@State private var loaded: (url: URL, image: UIImage)?

	private var maxPixels: Int { Int((maxPoints * displayScale).rounded(.up)) }

	private var image: UIImage? {
		guard let url else { return nil }
		if let loaded, loaded.url == url { return loaded.image }
		// Already in memory: no placeholder flash when a row scrolls back in.
		return ImagePipeline.shared.cached(url, maxPixels: maxPixels, minimumPixels: minimumPixels)
	}

	var body: some View {
		Group {
			if let image {
				content(image)
			} else {
				placeholder()
			}
		}
		.task(id: url) {
			guard let url, ImagePipeline.shared.cached(url, maxPixels: maxPixels, minimumPixels: minimumPixels) == nil else { return }
			if let image = await ImagePipeline.shared.image(url, maxPixels: maxPixels, minimumPixels: minimumPixels) {
				loaded = (url, image)
			}
		}
	}
}
