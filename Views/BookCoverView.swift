import SwiftUI
import UIKit

/// Displays a book's cover artwork from `Data` or a stylized typographic fallback cover.
struct BookCoverView: View {
    let title: String
    let author: String
    let artworkData: Data?
    var cornerRadius: CGFloat = 14

    var body: some View {
        Color.clear
            .overlay {
                if let artworkData, let uiImage = UIImage(data: artworkData) {
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
/// so iOS 27 Liquid Glass controls refract and adapt naturally in both Light and Dark Mode.
struct AmbientCoverBackdropView: View {
    let artworkData: Data?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let artworkData, let uiImage = UIImage(data: artworkData) {
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
        }
        .ignoresSafeArea()
    }
}
