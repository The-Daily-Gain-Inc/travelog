import SwiftUI

/// Photo grid for one country's album, shown from the world map.
struct CountryGridView: View {
    let album: Album
    @Environment(\.dismiss) private var dismiss
    @State private var showSlideshow = false

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 4)]

    private var items: [MediaItem] {
        album.items.sorted { $0.createdTime < $1.createdTime }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(items) { item in
                        MediaThumbnail(item: item)
                            .aspectRatio(1, contentMode: .fill)
                    }
                }
                .padding(4)
            }
            .navigationTitle(album.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        DownloadManager.shared.download(album)
                    } label: {
                        Label("Download for Offline", systemImage: "arrow.down.circle")
                    }
                    .disabled(DownloadManager.shared.isDownloading(album))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSlideshow = true
                    } label: {
                        Label("Slideshow", systemImage: "play.fill")
                    }
                }
            }
            .fullScreenCover(isPresented: $showSlideshow) {
                SlideshowView(album: album)
            }
        }
    }
}

struct MediaThumbnail: View {
    let item: MediaItem
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            if item.isVideo {
                Image(systemName: "video.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task {
            guard image == nil else { return }
            image = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name))
        }
    }
}
