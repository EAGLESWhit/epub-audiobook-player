import SwiftUI
import UIKit

/// Main-actor in-memory decoded `UIImage` cache for book cover artwork so SwiftUI redraws
/// and scrolling library lists never re-decode JPEG/PNG `Data` on the main thread.
@MainActor
enum CoverImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 64
        c.totalCostLimit = 32 * 1024 * 1024 // 32 MB decoded bitmap budget
        return c
    }()

    static func image(for data: Data?) -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        let key = cacheKey(for: data)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let decoded = UIImage(data: data) else { return nil }
        let pixelCost = Int(decoded.size.width * decoded.scale * decoded.size.height * decoded.scale * 4)
        cache.setObject(decoded, forKey: key, cost: max(1, pixelCost))
        return decoded
    }

    private static func cacheKey(for data: Data) -> NSString {
        let prefix = data.prefix(24).base64EncodedString()
        let suffix = data.suffix(24).base64EncodedString()
        return "\(data.count)-\(prefix)-\(suffix)" as NSString
    }
}

/// Displays a book's cover artwork from `Data` (via `CoverImageCache`) or a stylized typographic fallback cover.
struct BookCoverView: View {
    let title: String
    let author: String
    let artworkData: Data?
    var cornerRadius: CGFloat = 14

    var body: some View {
        Color.clear
            .overlay {
                if let uiImage = CoverImageCache.image(for: artworkData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    fallbackCover
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.8)
            )
    }

    private var fallbackCover: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.22, blue: 0.44),
                    Color(red: 0.26, green: 0.18, blue: 0.42),
                    Color(red: 0.48, green: 0.25, blue: 0.36)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                Image(systemName: "book.pages.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.75))

                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 8)

                Text(author)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
            .padding(.vertical, 10)
        }
    }
}

/// Renders a soft, ambient blurred backdrop derived from the current book's cover art
/// rasterized via `.drawingGroup()` so scrolling reader text stays locked at 120 fps.
struct AmbientCoverBackdropView: View {
    let artworkData: Data?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let uiImage = CoverImageCache.image(for: artworkData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width * 1.25, height: proxy.size.height * 1.25)
                        .blur(radius: 68)
                        .saturation(1.25)
                        .offset(x: -proxy.size.width * 0.12, y: -proxy.size.height * 0.1)
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.15, green: 0.25, blue: 0.50),
                            Color(red: 0.35, green: 0.20, blue: 0.48),
                            Color(red: 0.10, green: 0.16, blue: 0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .blur(radius: 40)
                }

                // Adaptive contrast wash so scrolling text remains crisp in both Light and Dark Mode
                Rectangle()
                    .fill(
                        colorScheme == .dark
                            ? Color.black.opacity(0.50)
                            : Color.white.opacity(0.58)
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .drawingGroup()
        }
        .ignoresSafeArea()
    }
}
