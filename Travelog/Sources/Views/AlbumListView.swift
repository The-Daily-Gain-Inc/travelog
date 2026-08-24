import SwiftUI
import SwiftData

/// Slideshow tab: iPad-friendly grid of album cards; tapping one starts the slideshow.
struct AlbumListView: View {
    @Query(sort: \Album.name) private var albums: [Album]
    @EnvironmentObject private var sync: SyncService
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var slideshowAlbum: Album?
    @State private var surpriseMe = false

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
                                AlbumCard(album: album, downloadProgress: downloads.progress[album.driveId])
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    downloads.download(album)
                                } label: {
                                    Label("Download for Offline", systemImage: "arrow.down.circle")
                                }
                                .disabled(downloads.isDownloading(album))
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Albums")
            .toolbar {
                if !albums.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            surpriseMe = true
                        } label: {
                            Label("Surprise Me", systemImage: "shuffle")
                        }
                    }
                }
                if sync.isSyncing {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(sync.progressText ?? String(localized: "Syncing…"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .fullScreenCover(item: $slideshowAlbum) { album in
                SlideshowView(album: album)
            }
            .fullScreenCover(isPresented: $surpriseMe) {
                SlideshowView(
                    title: String(localized: "Surprise Me"),
                    items: albums.flatMap(\.items),
                    forceShuffle: true
                )
            }
        }
    }
}

struct AlbumCard: View {
    let album: Album
    var downloadProgress: Double?
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
                if let downloadProgress {
                    VStack {
                        HStack {
                            Spacer()
                            ProgressView(value: downloadProgress)
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .background(.black.opacity(0.4), in: Circle())
                                .padding(10)
                        }
                        Spacer()
                    }
                }
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
            guard cover == nil, let item = coverItem else { return }
            cover = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name))
        }
    }
}
