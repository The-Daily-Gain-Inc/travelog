import SwiftUI
import SwiftData

/// Slideshow tab: iPad-friendly grid of album cards; tapping one starts the slideshow.
struct AlbumListView: View {
    @Query(sort: \Album.name) private var albums: [Album]
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var auth: AuthService
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var slideshowAlbum: Album?
    @State private var surpriseMe = false
    @State private var favoritesShow = false
    @State private var onThisDayShow = false
    @State private var shuffleAlbum: Album?
    @State private var recentsShow = false
    @State private var searchText = ""
    @AppStorage("albumSort") private var albumSort = "name"
    @AppStorage("rootFolderName") private var rootFolderName = "Travelog"

    /// Albums filtered by search text and ordered by the chosen sort.
    private var displayAlbums: [Album] {
        var list = searchText.isEmpty ? albums : albums.filter {
            WorldGeometry.normalize($0.name).contains(WorldGeometry.normalize(searchText))
        }
        switch albumSort {
        case "count":
            list.sort { $0.items.count > $1.items.count }
        case "recent":
            list.sort {
                ($0.items.map(\.createdTime).max() ?? .distantPast) >
                ($1.items.map(\.createdTime).max() ?? .distantPast)
            }
        default:
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 20)]

    private var favorites: [MediaItem] {
        albums.flatMap(\.items).filter { $0.isFavorite && !$0.isHidden }
    }

    /// Photos taken within ±3 days of today's date in earlier years.
    private var onThisDay: [MediaItem] {
        let calendar = Calendar.current
        let today = calendar.ordinality(of: .day, in: .year, for: .now) ?? 0
        let thisYear = calendar.component(.year, from: .now)
        return albums.flatMap(\.items).filter { item in
            guard !item.isHidden,
                  calendar.component(.year, from: item.createdTime) < thisYear,
                  let day = calendar.ordinality(of: .day, in: .year, for: item.createdTime) else { return false }
            return abs(day - today) <= 3
        }.sorted { $0.createdTime < $1.createdTime }
    }

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
                    if !onThisDay.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("On This Day", systemImage: "calendar.badge.clock")
                                .font(.title3.bold())
                                .padding(.horizontal, 20)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(onThisDay) { item in
                                        OnThisDayCard(item: item)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                        .padding(.top, 12)
                        .onTapGesture { onThisDayShow = true }
                    }
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(displayAlbums) { album in
                            Button { slideshowAlbum = album } label: {
                                AlbumCard(album: album, downloadProgress: downloads.progress[album.driveId])
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    shuffleAlbum = album
                                } label: {
                                    Label("Play Shuffled", systemImage: "shuffle")
                                }
                                Button {
                                    TourController.shared.focusAlbumId = album.driveId
                                } label: {
                                    Label("Show on Map", systemImage: "globe.europe.africa")
                                }
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
            .searchable(text: $searchText, prompt: Text("Search countries"))
            .refreshable {
                if auth.isSignedIn {
                    await sync.sync(rootFolderName: rootFolderName, context: modelContext)
                }
            }
            .toolbar {
                if !albums.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort by", selection: $albumSort) {
                                Label("Name", systemImage: "textformat").tag("name")
                                Label("Photo count", systemImage: "number").tag("count")
                                Label("Most recent", systemImage: "clock").tag("recent")
                            }
                            Divider()
                            Button {
                                recentsShow = true
                            } label: {
                                Label("Play Recent Memories", systemImage: "sparkles.rectangle.stack")
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            surpriseMe = true
                        } label: {
                            Label("Surprise Me", systemImage: "shuffle")
                        }
                    }
                    if !favorites.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                favoritesShow = true
                            } label: {
                                Label("Favorites", systemImage: "heart.fill")
                            }
                            .tint(.red)
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
            .fullScreenCover(isPresented: $favoritesShow) {
                SlideshowView(title: String(localized: "Favorites"), items: favorites)
            }
            .fullScreenCover(isPresented: $onThisDayShow) {
                SlideshowView(title: String(localized: "On This Day"), items: onThisDay)
            }
            .fullScreenCover(item: $shuffleAlbum) { album in
                SlideshowView(title: album.name, items: album.items, forceShuffle: true)
            }
            .fullScreenCover(isPresented: $recentsShow) {
                SlideshowView(
                    title: String(localized: "Recent Memories"),
                    items: Array(albums.flatMap(\.items)
                        .filter { !$0.isHidden }
                        .sorted { $0.createdTime > $1.createdTime }
                        .prefix(30))
                )
            }
        }
    }
}

struct OnThisDayCard: View {
    let item: MediaItem
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            Text(item.createdTime.formatted(.dateTime.year()))
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(6)
        }
        .frame(width: 150, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            image = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name))
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
