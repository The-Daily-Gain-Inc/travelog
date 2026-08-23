import SwiftUI
import SwiftData

/// Slideshow tab: iPad-friendly grid of album cards; tapping one starts the slideshow.
struct AlbumListView: View {
    @Query(sort: \Album.name) private var albums: [Album]
    @State private var slideshowAlbum: Album?

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 20)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if albums.isEmpty {
                    ContentUnavailableView(
                        "No Albums Yet",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Sync your Google Drive from Settings to load your albums.")
                    )
                    .padding(.top, 120)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(albums) { album in
                            Button { slideshowAlbum = album } label: {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Albums")
            .fullScreenCover(item: $slideshowAlbum) { album in
                SlideshowView(album: album)
            }
        }
    }
}

struct AlbumCard: View {
    let album: Album
    @State private var cover: UIImage?

    private var coverItem: MediaItem? {
        album.items.filter { !$0.isVideo }.min { $0.createdTime < $1.createdTime }
            ?? album.items.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 6)
            }
            .frame(height: 190)
            .clipped()

            HStack {
                Text(album.name)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(album.items.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.thinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .task(id: coverItem?.driveId) {
            guard cover == nil, let item = coverItem, !item.isVideo else { return }
            cover = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name))
        }
    }
}
