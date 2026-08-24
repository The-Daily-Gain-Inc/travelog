import SwiftUI

/// Photo grid for one country's album, shown from the world map. Photos are
/// grouped into region sections (geocoded from their GPS) once known.
struct CountryGridView: View {
    let album: Album
    @Environment(\.dismiss) private var dismiss
    @State private var showSlideshow = false
    @State private var startItem: MediaItem?
    @State private var regionGroups: [(name: String, items: [MediaItem])] = []
    @State private var postcard: UIImage?
    @State private var collage: UIImage?
    @State private var postcardMessage = ""
    @State private var showMessagePrompt = false
    @AppStorage("showHiddenItems") private var showHiddenItems = false
    @State private var sortDescending = false
    @State private var editingNote = false
    @State private var noteDraft = ""

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 4)]

    private var items: [MediaItem] {
        album.items
            .filter { showHiddenItems || !$0.isHidden }
            .sorted {
                sortDescending ? $0.createdTime > $1.createdTime : $0.createdTime < $1.createdTime
            }
    }

    private var headerStats: some View {
        HStack(spacing: 18) {
            Text(WorldGeometry.feature(for: album).flatMap { WorldGeometry.flag(for: $0) } ?? "🌍")
                .font(.system(size: 54))
            VStack(alignment: .leading, spacing: 4) {
                let photos = items.filter { !$0.isVideo }.count
                let videos = items.count - photos
                Text(videos > 0 ? "\(photos) photos · \(videos) videos" : "\(photos) photos")
                    .font(.headline)
                if let first = items.first?.createdTime, let last = items.last?.createdTime {
                    let a = first.formatted(.dateTime.month(.abbreviated).year())
                    let b = last.formatted(.dateTime.month(.abbreviated).year())
                    Text(a == b ? a : "\(a) – \(b)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if regionGroups.count > 1 {
                    Text("\(regionGroups.count) regions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                sortDescending.toggle()
            } label: {
                Label(sortDescending ? "Newest first" : "Oldest first",
                      systemImage: sortDescending ? "arrow.down" : "arrow.up")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var noteRow: some View {
        Button {
            noteDraft = album.note
            editingNote = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: album.note.isEmpty ? "square.and.pencil" : "note.text")
                Text(album.note.isEmpty ? String(localized: "Add a note about this trip…") : album.note)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .font(.subheadline)
            .foregroundStyle(album.note.isEmpty ? .secondary : .primary)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                headerStats
                noteRow
                if regionGroups.count > 1 {
                    LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                        ForEach(regionGroups, id: \.name) { group in
                            Section {
                                LazyVGrid(columns: columns, spacing: 4) {
                                    ForEach(group.items) { item in
                                        TappableThumbnail(item: item) { startItem = item }
                                            .aspectRatio(1, contentMode: .fill)
                                    }
                                }
                                .padding(.horizontal, 4)
                            } header: {
                                Text(group.name)
                                    .font(.headline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(.leading, 8)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(items) { item in
                            TappableThumbnail(item: item) { startItem = item }
                                .aspectRatio(1, contentMode: .fill)
                        }
                    }
                    .padding(4)
                }
            }
            .navigationTitle(album.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                if postcard != nil || collage != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if let postcard {
                                ShareLink(
                                    item: Image(uiImage: postcard),
                                    preview: SharePreview(
                                        Text("Postcard from \(album.name)"),
                                        image: Image(uiImage: postcard)
                                    )
                                ) {
                                    Label("Share Postcard", systemImage: "envelope")
                                }
                            }
                            Button {
                                showMessagePrompt = true
                            } label: {
                                Label("Personalize Postcard…", systemImage: "pencil.line")
                            }
                            if let collage {
                                ShareLink(
                                    item: Image(uiImage: collage),
                                    preview: SharePreview(
                                        Text("\(album.name) collage"),
                                        image: Image(uiImage: collage)
                                    )
                                ) {
                                    Label("Share Collage", systemImage: "square.grid.3x3")
                                }
                            }
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
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
            .fullScreenCover(item: $startItem) { item in
                SlideshowView(album: album, startItem: item)
            }
            .task { await buildRegionGroups() }
            .task { await buildPostcard() }
            .alert(Text("Album note"), isPresented: $editingNote) {
                TextField(String(localized: "Note"), text: $noteDraft)
                Button("Save") { album.note = noteDraft }
                Button("Cancel", role: .cancel) {}
            }
            .alert(Text("Postcard message"), isPresented: $showMessagePrompt) {
                TextField(String(localized: "Your message"), text: $postcardMessage)
                Button("Update Postcard") {
                    Task { await buildPostcard() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Written along the bottom of the shared postcard.")
            }
        }
    }

    /// Groups located photos by geocoded region; unlocated ones land in "Other".
    private func buildRegionGroups() async {
        var byRegion: [String: [MediaItem]] = [:]
        for item in items {
            var key = String(localized: "Other")
            if let lat = item.latitude, let lon = item.longitude,
               let region = await PlaceLookup.shared.region(latitude: lat, longitude: lon) {
                key = region
            }
            byRegion[key, default: []].append(item)
        }
        guard byRegion.count > 1 else { return }
        let other = String(localized: "Other")
        regionGroups = byRegion
            .sorted { a, b in
                if a.key == other { return false }
                if b.key == other { return true }
                return a.key < b.key
            }
            .map { (name: $0.key, items: $0.value) }
    }

    private func buildPostcard() async {
        let photoItems = items.filter { !$0.isVideo }.prefix(4)
        guard !photoItems.isEmpty else { return }
        var thumbs: [UIImage] = []
        for item in photoItems {
            if let img = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name), maxPixel: 800) {
                thumbs.append(img)
            }
        }
        guard !thumbs.isEmpty else { return }
        let flag = WorldGeometry.feature(for: album).flatMap { WorldGeometry.flag(for: $0) } ?? "🌍"
        let view = PostcardView(countryName: album.name, flag: flag, photos: thumbs,
                                message: postcardMessage)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        postcard = renderer.uiImage
        await buildCollage()
    }

    /// 3×3 photo collage rendered offscreen.
    private func buildCollage() async {
        let photoItems = items.filter { !$0.isVideo }.prefix(9)
        guard photoItems.count >= 4 else { return }
        var thumbs: [UIImage] = []
        for item in photoItems {
            if let img = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name), maxPixel: 500) {
                thumbs.append(img)
            }
        }
        guard thumbs.count >= 4 else { return }
        let cell: CGFloat = 396, spacing: CGFloat = 6
        let size = CGSize(width: cell * 3 + spacing * 4, height: cell * 3 + spacing * 4)
        let renderer = UIGraphicsImageRenderer(size: size)
        collage = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, thumb) in thumbs.enumerated() {
                let row = CGFloat(i / 3), col = CGFloat(i % 3)
                let rect = CGRect(x: spacing + col * (cell + spacing),
                                  y: spacing + row * (cell + spacing),
                                  width: cell, height: cell)
                ctx.cgContext.saveGState()
                UIBezierPath(roundedRect: rect, cornerRadius: 14).addClip()
                // Aspect-fill the square cell.
                let scale = max(rect.width / thumb.size.width, rect.height / thumb.size.height)
                let drawSize = CGSize(width: thumb.size.width * scale, height: thumb.size.height * scale)
                thumb.draw(in: CGRect(
                    x: rect.midX - drawSize.width / 2,
                    y: rect.midY - drawSize.height / 2,
                    width: drawSize.width, height: drawSize.height
                ))
                ctx.cgContext.restoreGState()
            }
        }
    }
}

/// Rendered offscreen and shared as an image.
struct PostcardView: View {
    let countryName: String
    let flag: String
    let photos: [UIImage]
    var message: String = ""

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Text(flag).font(.system(size: 56))
                Text(countryName)
                    .font(.system(size: 44, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                Spacer()
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    postcardPhoto(0)
                    postcardPhoto(1)
                }
                GridRow {
                    postcardPhoto(2)
                    postcardPhoto(3)
                }
            }
            HStack {
                Spacer()
                Text(message.isEmpty ? String(localized: "— with love, from my Travelog") : message)
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .italic()
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .padding(36)
        .frame(width: 840)
        .background(
            LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.28),
                                    Color(red: 0.32, green: 0.18, blue: 0.30)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    @ViewBuilder
    private func postcardPhoto(_ index: Int) -> some View {
        if photos.indices.contains(index) {
            Image(uiImage: photos[index])
                .resizable()
                .scaledToFill()
                .frame(width: 374, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.08))
                .frame(width: 374, height: 280)
        }
    }
}

/// Grid thumbnail that opens the slideshow at its photo, with a long-press
/// menu for favorite/hide/copy/save (and optional selection styling).
struct TappableThumbnail: View {
    let item: MediaItem
    var onShowAlbum: (() -> Void)? = nil
    var selected: Bool? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            MediaThumbnail(item: item)
                .overlay(alignment: .topTrailing) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected ? Color.appAccent : .white)
                            .shadow(radius: 3)
                            .padding(6)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                item.isFavorite.toggle()
            } label: {
                Label(item.isFavorite ? "Remove Favorite" : "Favorite",
                      systemImage: item.isFavorite ? "heart.slash" : "heart")
            }
            Button {
                item.isHidden.toggle()
            } label: {
                Label(item.isHidden ? "Unhide" : "Hide",
                      systemImage: item.isHidden ? "eye" : "eye.slash")
            }
            if !item.isVideo {
                Button {
                    item.album?.coverDriveId = item.driveId
                } label: {
                    Label("Set as Album Cover", systemImage: "rectangle.stack.badge.person.crop")
                }
                Button {
                    Task {
                        if let url = try? await MediaCache.shared.file(for: (item.driveId, item.name)),
                           let image = UIImage(contentsOfFile: url.path) {
                            UIPasteboard.general.image = image
                        }
                    }
                } label: {
                    Label("Copy Photo", systemImage: "doc.on.doc")
                }
                Button {
                    Task {
                        if let url = try? await MediaCache.shared.file(for: (item.driveId, item.name)),
                           let image = UIImage(contentsOfFile: url.path) {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        }
                    }
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
            }
            if let onShowAlbum {
                Button(action: onShowAlbum) {
                    Label("Show in Album", systemImage: "folder")
                }
            }
        }
    }
}

struct MediaThumbnail: View {
    let item: MediaItem
    @State private var image: UIImage?

    var body: some View {
        // The image is drawn as an overlay so its natural size can never
        // drive layout — the grid cell decides, the photo fills and clips.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay {
                if item.isVideo {
                    Image(systemName: "video.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .shadow(radius: 3)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .opacity(item.isHidden ? 0.4 : 1)
            .task {
                guard image == nil else { return }
                image = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name))
            }
    }
}