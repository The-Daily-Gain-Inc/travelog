import SwiftUI
import AVKit
import MapKit

/// Fullscreen slideshow over any set of photos and videos (an album, a map
/// cluster, or the whole library). Photos auto-advance with a Ken Burns drift;
/// videos play through. Tapping reveals playback controls, a scrubber,
/// slide-duration picker and a mini-map of where the current photo was taken.
struct SlideshowView: View {
    let title: String
    let baseItems: [MediaItem]
    let countryName: String?
    let forceShuffle: Bool

    init(album: Album) {
        self.init(title: album.name, items: album.items, countryName: album.name)
    }

    init(title: String, items: [MediaItem], countryName: String? = nil, forceShuffle: Bool = false) {
        self.title = title
        self.baseItems = items
        self.countryName = countryName
        self.forceShuffle = forceShuffle
    }

    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var loadError = false
    @State private var showControls = false
    @State private var isPlaying = true
    @State private var scrubIndex: Double = 0
    @State private var isScrubbing = false
    @State private var kenBurnsActive = false
    @State private var caption: String?
    @State private var shuffleSeed = UInt64.random(in: 1...UInt64.max)
    @State private var advanceTask: Task<Void, Never>?
    @State private var hideControlsTask: Task<Void, Never>?

    @AppStorage("slideDuration") private var slideDuration: Double = 5
    @AppStorage("showsMiniMap") private var showsMiniMap = true
    @AppStorage("skipLivePhotos") private var skipLivePhotos = true
    @AppStorage("kenBurns") private var kenBurns = true
    @AppStorage("showCaptions") private var showCaptions = true
    @AppStorage("shuffleSlides") private var shuffleSlides = false
    @AppStorage("displayMaxPixel") private var displayMaxPixel: Double = 0

    private var items: [MediaItem] {
        var all = baseItems.sorted { $0.createdTime < $1.createdTime }
        if skipLivePhotos {
            // A Live Photo exports as a still + a tiny video sharing the same
            // basename; drop those companions so only real videos play.
            let photoStems = Set(all.filter { !$0.isVideo }.map { stem($0.name) })
            all = all.filter { !$0.isVideo || !photoStems.contains(stem($0.name)) }
        }
        if forceShuffle || shuffleSlides {
            var rng = SeededRandom(seed: shuffleSeed)
            all.shuffle(using: &rng)
        }
        return all
    }

    private func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased()
    }

    private var currentItem: MediaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// Where the current photo was taken; falls back to its album's country.
    private var currentCoordinate: CLLocationCoordinate2D? {
        if let lat = currentItem?.latitude, let lon = currentItem?.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        let country = currentItem?.album?.name ?? countryName
        return country.flatMap { WorldGeometry.centroid(forCountryNamed: $0) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(kenBurnsActive ? 1.09 : 1.0, anchor: kenBurnsAnchor)
                    .animation(kenBurnsActive ? .linear(duration: slideDuration + 1) : nil, value: kenBurnsActive)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .id(index)
            } else if loadError {
                ContentUnavailableView("Couldn’t load this item", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }

            if showCaptions, let caption, !showControls {
                VStack {
                    Spacer()
                    HStack {
                        Text(caption)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.35), in: Capsule())
                            .padding(20)
                        Spacer()
                    }
                }
                .transition(.opacity)
            }

            if showControls {
                overlayControls
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.width < 0 { advance(by: 1) } else { advance(by: -1) }
            }
        )
        .task { await show(index: 0) }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            advanceTask?.cancel()
            hideControlsTask?.cancel()
            player?.pause()
        }
    }

    private var kenBurnsAnchor: UnitPoint {
        let anchors: [UnitPoint] = [.topLeading, .bottomTrailing, .topTrailing, .bottomLeading, .center]
        return anchors[index % anchors.count]
    }

    // MARK: - Overlay

    private var overlayControls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if showsMiniMap, let coordinate = currentCoordinate {
                HStack {
                    Spacer()
                    miniMap(coordinate: coordinate)
                        .padding(.trailing, 24)
                        .padding(.bottom, 16)
                }
            }
            bottomBar
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Text("\(title) · \(index + 1)/\(items.count)")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial.opacity(0.7), in: Capsule())
                .environment(\.colorScheme, .dark)
        }
        .padding(24)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if items.count > 1 {
                Slider(
                    value: $scrubIndex,
                    in: 0...Double(max(items.count - 1, 1)),
                    step: 1
                ) { editing in
                    isScrubbing = editing
                    if !editing { advance(to: Int(scrubIndex)) }
                }
                .tint(.white)
            }

            HStack(spacing: 8) {
                optionsMenu
                Spacer()
                HStack(spacing: 36) {
                    controlButton("backward.end.fill", size: 26) { advance(by: -1) }
                    controlButton(isPlaying ? "pause.circle.fill" : "play.circle.fill", size: 56) { togglePlay() }
                    controlButton("forward.end.fill", size: 26) { advance(by: 1) }
                }
                Spacer()
                controlButton(showsMiniMap ? "map.fill" : "map", size: 22) {
                    withAnimation { showsMiniMap.toggle() }
                    scheduleControlsAutoHide()
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial.opacity(0.75), in: RoundedRectangle(cornerRadius: 24))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Slide duration", selection: $slideDuration) {
                Text("2 s").tag(2.0)
                Text("5 s").tag(5.0)
                Text("8 s").tag(8.0)
                Text("15 s").tag(15.0)
            }
            Divider()
            Toggle("Shuffle", isOn: $shuffleSlides)
            Toggle("Ken Burns effect", isOn: $kenBurns)
            Toggle("Captions", isOn: $showCaptions)
            Toggle("Skip Live Photo clips", isOn: $skipLivePhotos)
        } label: {
            Label("\(Int(slideDuration)) s", systemImage: "timer")
                .font(.subheadline.bold())
                .foregroundStyle(.white.opacity(0.9))
        }
        .onChange(of: slideDuration) {
            if isPlaying, player == nil { scheduleAdvance() }
        }
        .onChange(of: skipLivePhotos) { advance(to: index) }
        .onChange(of: shuffleSlides) { advance(to: 0) }
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private func miniMap(coordinate: CLLocationCoordinate2D) -> some View {
        Map(position: .constant(.camera(MapCamera(centerCoordinate: coordinate, distance: 9_000_000)))) {
            Marker(title, coordinate: coordinate)
                .tint(.orange)
        }
        .mapStyle(.imagery(elevation: .flat))
        .allowsHitTesting(false)
        .frame(width: 230, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .shadow(radius: 12)
        .id(index)
    }

    // MARK: - Control state

    private func toggleControls() {
        withAnimation { showControls.toggle() }
        if showControls { scheduleControlsAutoHide() } else { hideControlsTask?.cancel() }
    }

    private func scheduleControlsAutoHide() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, !isScrubbing else { return }
            withAnimation { showControls = false }
        }
    }

    private func togglePlay() {
        isPlaying.toggle()
        if isPlaying {
            if let player { player.play() } else { scheduleAdvance() }
        } else {
            advanceTask?.cancel()
            player?.pause()
        }
        scheduleControlsAutoHide()
    }

    // MARK: - Advancing

    private func advance(by delta: Int) {
        guard !items.isEmpty else { return }
        advance(to: (index + delta + items.count) % items.count)
    }

    private func advance(to newIndex: Int) {
        let clamped = items.isEmpty ? 0 : min(max(newIndex, 0), items.count - 1)
        advanceTask?.cancel()
        advanceTask = Task { await show(index: clamped) }
        scheduleControlsAutoHide()
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        advanceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(slideDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            advance(by: 1)
        }
    }

    private func show(index newIndex: Int) async {
        guard !items.isEmpty else { loadError = true; return }
        index = newIndex
        scrubIndex = Double(newIndex)
        let item = items[newIndex]
        player?.pause()
        player = nil
        image = nil
        caption = nil
        kenBurnsActive = false
        loadError = false

        updateCaption(for: item)

        if item.isVideo {
            guard let url = try? await MediaCache.shared.file(for: (item.driveId, item.name)) else {
                loadError = true
                return
            }
            guard !Task.isCancelled else { return }
            let p = AVPlayer(url: url)
            player = p
            if isPlaying { p.play() }
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: p.currentItem, queue: .main
            ) { _ in
                Task { @MainActor in advance(by: 1) }
            }
        } else {
            guard let loaded = try? await MediaCache.shared.displayImage(
                for: (item.driveId, item.name), maxPixel: displayMaxPixel
            ) else {
                loadError = true
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                image = loaded
            }
            if kenBurns { kenBurnsActive = true }
            // Prefetch the next item while this one is on screen.
            if items.count > 1 {
                let next = items[(newIndex + 1) % items.count]
                Task.detached { _ = try? await MediaCache.shared.file(for: (next.driveId, next.name)) }
            }
            if isPlaying { scheduleAdvance() }
        }
    }

    private func updateCaption(for item: MediaItem) {
        let date = item.createdTime.formatted(.dateTime.month(.wide).year())
        caption = date
        guard let lat = item.latitude, let lon = item.longitude else { return }
        let shownIndex = index
        Task {
            if let place = await PlaceLookup.shared.place(latitude: lat, longitude: lon),
               index == shownIndex {
                caption = "\(place) · \(date)"
            }
        }
    }
}

/// Deterministic RNG so a shuffled slideshow keeps its order for its lifetime.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
