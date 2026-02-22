//
//  ConversationAttachmentStripView.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI
import Foundation

struct ConversationAttachmentStripView: View {
    let imageURLs: [String]
    let localImagePaths: [String]

    private enum Layout {
        static let cornerRadius: CGFloat = 10
        static let width: CGFloat = 180
        static let height: CGFloat = 120
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(imageURLs.enumerated()), id: \.offset) { _, url in
                    attachmentPreview(remoteURLString: url)
                }
                ForEach(Array(localImagePaths.enumerated()), id: \.offset) { _, path in
                    attachmentPreview(localPath: path)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func attachmentPreview(remoteURLString: String) -> some View {
        if let image = imageFromDataURI(remoteURLString) {
            platformImageView(image)
        } else if let remoteURL = URL(string: remoteURLString), remoteURL.scheme != nil {
            AsyncImage(url: remoteURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure(_):
                    attachmentPlaceholder(title: "Image")
                case .empty:
                    ZStack {
                        attachmentPlaceholder(title: "Loading image")
                        ProgressView()
                    }
                @unknown default:
                    attachmentPlaceholder(title: "Image")
                }
            }
            .frame(width: Layout.width, height: Layout.height)
            .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
        } else {
            attachmentPlaceholder(title: "Image")
        }
    }

    @ViewBuilder
    private func attachmentPreview(localPath: String) -> some View {
        if let image = imageFromFile(path: localPath) {
            platformImageView(image)
        } else {
            attachmentPlaceholder(title: URL(fileURLWithPath: localPath).lastPathComponent)
        }
    }

    private func attachmentPlaceholder(title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
            Text(title)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .frame(width: Layout.width, height: Layout.height)
        .background(
            Color.secondary.opacity(0.09),
            in: RoundedRectangle(cornerRadius: Layout.cornerRadius)
        )
    }

    @ViewBuilder
    private func platformImageView(_ image: PlatformImage) -> some View {
        #if os(iOS)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: Layout.width, height: Layout.height)
            .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
        #else
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: Layout.width, height: Layout.height)
            .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
        #endif
    }

    private func imageFromDataURI(_ value: String) -> PlatformImage? {
        guard value.hasPrefix("data:image/") else { return nil }
        guard let commaIndex = value.firstIndex(of: ",") else { return nil }
        let meta = String(value[..<commaIndex]).lowercased()
        guard meta.contains(";base64") else { return nil }
        let encoded = String(value[value.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else { return nil }
        #if os(iOS)
        return UIImage(data: data)
        #else
        return NSImage(data: data)
        #endif
    }

    private func imageFromFile(path: String) -> PlatformImage? {
        #if os(iOS)
        return UIImage(contentsOfFile: path)
        #else
        return NSImage(contentsOfFile: path)
        #endif
    }
}
