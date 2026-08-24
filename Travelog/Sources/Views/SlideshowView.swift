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
    /// When true, reaching the end of the last slide dismisses the show
    /// instead of looping — used by the map's World Tour to hop countries.
    let closeAtEnd: Bool
    /// Starts the show on this item instead of the first one.
    let startItem: MediaItem?

    init(album: Album, closeAtEnd: Bool = false, startItem: MediaItem? = nil) {
        self.init(title: album.name, items: album.items, countryName: album.name,
                  closeAtEnd: closeAtEnd, startItem: startItem)
    }

    init(title: String, items: [MediaItem], countryName: String? = nil,
         forceShuffle: Bool = false, closeAtEnd: Bool = false, startItem: MediaItem? = nil) {
        self.title = title
        self.baseItems = items
        self.countryName = countryName
        self.forceShuffle = forceShuffle
        self.closeAtEnd = closeAtEnd
        self.startItem = startItem
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
    @State private var showInfo = false
    @State private var infoPlace: String?
    @State private var slideStart: Date?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var heartBurst = false
    @State private var currentFileURL: URL?
    @AppStorage("videoLimitSeconds") private var videoLimitSeconds: Double = 0
    @AppStorage("sleepTimerMinutes") private var sleepTimerMinutes: Double = 0
    @AppStorage("showClock") private var showClock = false
    @AppStorage("loopSlideshow") private var loopSlideshow = true
    @AppStorage("newestFirst") private var newestFirst = false
    @AppStorage("dimInFrame") private var dimInFrame = false
    @State private var photoRotation: Angle = .zero
    @State private var savedBrightness: CGFloat?
    @State private var shuffleSeed = UInt64.random(in: 1...UInt64.max)
    @State private var advanceTask: Task<Void, Never>?
    @State private var hideControlsTask: Task<Void, Never>?

    @AppStorage("slideDuration") private var slideDuration: Double = 5
    @AppStorage("showsMiniMap") private var showsMiniMap = true
    @AppStorage("skipLivePhotos") private var skipLivePhotos = true
    @AppStorage("kenBurns") private var kenBurns = true
    @AppStorage("transitionStyle") private var transitionStyle = "fade"
    @AppStorage("muteVideos") private var muteVideos = false
    @AppStorage("showCaptions") private var showCaptions = true
    @AppStorage("shuffleSlides") private var shuffleSlides = false
    @AppStorage("displayMaxPixel") private var displayMaxPixel: Double = 0

    private var items: [MediaItem] {
        var all = baseItems.filter { !$0.isHidden }.sorted {
            newestFirst ? $0.createdTime > $1.createdTime : $0.createdTime < $1.createdTime
        }
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
        if let album = currentItem?.album, let feature = WorldGeometry.feature(for: album) {
            return WorldGeometry.centroid(of: feature)
        }
        return countryName.flatMap { WorldGeometry.centroid(forCountryNamed: $0) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Blurred fill behind the photo instead of black letterboxing.
            if player == nil, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70)
                    .opacity(0.55)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(kenBurnsActive ? 1.09 : 1.0, anchor: kenBurnsAnchor)
                    .animation(kenBurnsActive ? .linear(duration: slideDuration + 1) : nil, value: kenBurnsActive)
                    .scaleEffect(min(max(zoom * pinch, 1), 5))
                    .rotationEffect(photoRotation)
                    .ignoresSafeArea()
                    .transition(photoTransition)
                    .id(index)
                    .gesture(
                        MagnificationGesture()
                            .updating($pinch) { value, state, _ in state = value }
                            .onEnded { value in
                                zoom = min(max(zoom * value, 1), 5)
                            }
                    )
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

            if showClock {
                VStack {
                    HStack {
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(context.date, style: .time)
                                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                                Text(context.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                    .font(.headline)
                                    .opacity(0.8)
                            }
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.55), radius: 6)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 96)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if heartBurst {
                Image(systemName: "heart.fill")
                    .font(.system(size: 130))
                    .foregroundStyle(.red)
                    .shadow(radius: 18)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if showControls {
                overlayControls
            }

            // Thin countdown to the next slide while auto-advancing.
            if isPlaying, player == nil, let slideStart {
                VStack {
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        let fraction = min(context.date.timeIntervalSince(slideStart) / slideDuration, 1)
                        GeometryReader { geo in
                            Rectangle()
                                .fill(Color.appAccent.opacity(0.85))
                                .frame(width: geo.size.width * fraction, height: 3)
                        }
                        .frame(height: 3)
                    }
                    Spacer()
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            currentItem?.isFavorite = true
            withAnimation(.spring(duration: 0.35)) { heartBurst = true }
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                withAnimation(.easeOut(duration: 0.3)) { heartBurst = false }
            }
        }
        .onTapGesture { toggleControls() }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.height > 130, abs(value.translation.width) < 90 {
                    dismiss()
                } else if value.translation.width < 0 {
                    advance(by: 1)
                } else {
                    advance(by: -1)
                }
            }
        )
        .task {
            var start = startItem.flatMap { s in items.firstIndex { $0.driveId == s.driveId } } ?? 0
            if startItem == nil, !forceShuffle {
                // Resume where this show was left off last time.
                let saved = UserDefaults.standard.integer(forKey: "resume-\(title)")
                if saved > 0, saved < items.count { start = saved }
            }
            await show(index: start)
        }
        .task {
            // Sleep timer: end the show after the configured stretch.
            guard sleepTimerMinutes > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(sleepTimerMinutes * 60 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            dismiss()
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { advance(by: -1); return .handled }
        .onKeyPress(.rightArrow) { advance(by: 1); return .handled }
        .onKeyPress(.space) { togglePlay(); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(KeyEquivalent("f")) {
            currentItem?.isFavorite.toggle()
            return .handled
        }
        .onChange(of: muteVideos) { player?.isMuted = muteVideos }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if dimInFrame, UserDefaults.standard.bool(forKey: "ambientMode") {
                savedBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = max(UIScreen.main.brightness - 0.35, 0.15)
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if let savedBrightness { UIScreen.main.brightness = savedBrightness }
            advanceTask?.cancel()
            hideControlsTask?.cancel()
            player?.pause()
        }
    }

    private var photoTransition: AnyTransition {
        switch transitionStyle {
        case "slide":
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case "zoom":
            .scale(scale: 1.18).combined(with: .opacity)
        case "flip":
            .asymmetric(
                insertion: .modifier(active: FlipEffect(angle: 85), identity: FlipEffect(angle: 0))
                    .combined(with: .opacity),
                removal: .modifier(active: FlipEffect(angle: -85), identity: FlipEffect(angle: 0))
                    .combined(with: .opacity)
            )
        default:
            .opacity
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
            if showInfo, let item = currentItem {
                HStack {
                    infoPanel(for: item)
                        .padding(.leading, 24)
                    Spacer()
                }
            }
            Spacer()
            if showsMiniMap, let coordinate = currentCoordinate {
                HStack {
                    Spacer()
                    miniMap(coordinate: coordinate)
                        .padding(.trailing, 24)
                        .padding(.bottom, 16)
                }
            }
            filmstrip
            bottomBar
        }
        .transition(.opacity)
    }

    /// Tappable strip of upcoming/past thumbnails.
    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.driveId) { i, item in
                        FilmstripThumb(item: item, isCurrent: i == index)
                            .id(i)
                            .onTapGesture { advance(to: i) }
                    }
                }
                .padding(.horizontal, 24)
            }
            .frame(height: 62)
            .padding(.bottom, 6)
            .onAppear { proxy.scrollTo(index, anchor: .center) }
            .onChange(of: index) {
                withAnimation { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Button {
                withAnimation { showInfo.toggle() }
                scheduleControlsAutoHide()
            } label: {
                Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.85))
            }
            if let currentFileURL {
                ShareLink(item: currentFileURL) {
                    Image(systemName: "square.and.arrow.up.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.85))
                }
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
                HStack(spacing: 20) {
                    controlButton("rotate.right", size: 20) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            photoRotation += .degrees(90)
                        }
                    }
                    Button {
                        currentItem?.isFavorite.toggle()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        scheduleControlsAutoHide()
                    } label: {
                        Image(systemName: currentItem?.isFavorite == true ? "heart.fill" : "heart")
                            .font(.system(size: 22))
                            .foregroundStyle(currentItem?.isFavorite == true ? .red : .white.opacity(0.9))
                    }
                    controlButton("eye.slash", size: 20) {
                        currentItem?.isHidden = true
                        // The list re-filters, so the same index is now the next item.
                        advance(to: index)
                    }
                    controlButton(showsMiniMap ? "map.fill" : "map", size: 22) {
                        withAnimation { showsMiniMap.toggle() }
                        scheduleControlsAutoHide()
                    }
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
            Toggle("Mute videos", isOn: $muteVideos)
            Toggle("Show clock", isOn: $showClock)
            Toggle("Loop at end", isOn: $loopSlideshow)
            Toggle("Newest first", isOn: $newestFirst)
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
        .onChange(of: newestFirst) { advance(to: 0) }
    }

    private func infoPanel(for item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.name, systemImage: item.isVideo ? "video" : "photo")
                .font(.subheadline.bold())
            Label(item.createdTime.formatted(date: .long, time: .shortened), systemImage: "calendar")
            if let infoPlace {
                Label(infoPlace, systemImage: "mappin.and.ellipse")
            }
            if let lat = item.latitude, let lon = item.longitude {
                Label(String(format: "%.4f, %.4f", lat, lon), systemImage: "location")
            }
            if item.sizeBytes > 0 {
                Label(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file),
                      systemImage: "internaldrive")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.92))
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .task(id: item.driveId) {
            infoPlace = nil
            guard let lat = item.latitude, let lon = item.longitude else { return }
            infoPlace = await PlaceLookup.shared.place(latitude: lat, longitude: lon)
        }
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
                .tint(Color.appAccent)
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
        if delta > 0, index == items.count - 1 {
            if closeAtEnd {
                dismiss()
                return
            }
            if !loopSlideshow {
                isPlaying = false
                advanceTask?.cancel()
                return
            }
        }
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
        slideStart = .now
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
        UserDefaults.standard.set(newIndex, forKey: "resume-\(title)")
        let item = items[newIndex]
        player?.pause()
        player = nil
        image = nil
        caption = nil
        kenBurnsActive = false
        loadError = false
        slideStart = nil
        zoom = 1
        photoRotation = .zero
        currentFileURL = nil

        updateCaption(for: item)

        if item.isVideo {
            guard let url = try? await MediaCache.shared.file(for: (item.driveId, item.name)) else {
                loadError = true
                return
            }
            guard !Task.isCancelled else { return }
            currentFileURL = url
            let p = AVPlayer(url: url)
            p.isMuted = muteVideos
            player = p
            if isPlaying { p.play() }
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: p.currentItem, queue: .main
            ) { _ in
                Task { @MainActor in advance(by: 1) }
            }
            // Optionally cap long videos so tours and photo-frame keep moving.
            if videoLimitSeconds > 0 {
                let shownIndex = newIndex
                advanceTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(videoLimitSeconds * 1_000_000_000))
                    guard !Task.isCancelled, index == shownIndex, isPlaying else { return }
                    advance(by: 1)
                }
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
            currentFileURL = try? await MediaCache.shared.file(for: (item.driveId, item.name))
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

/// 3D horizontal-flip used by the "Flip" transition.
struct FlipEffect: ViewModifier {
    let angle: Double
    func body(content: Content) -> some View {
        content.rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0))
    }
}

struct FilmstripThumb: View {
    let item: MediaItem
    let isCurrent: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.4))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 62, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isCurrent ? Color.appAccent : .white.opacity(0.25),
                              lineWidth: isCurrent ? 2.5 : 1)
        )
        .task {
            guard image == nil else { return }
            image = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name), maxPixel: 150)
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
