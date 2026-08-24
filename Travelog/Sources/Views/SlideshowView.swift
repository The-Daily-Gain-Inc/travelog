import SwiftUI
import AVKit
import MapKit

/// Fullscreen slideshow of an album's photos and videos. Status bar and home
/// indicator are hidden; photos auto-advance, videos play through to the end.
/// Tapping the image reveals an overlay with playback controls, a scrubber,
/// slide-duration picker and a mini-map of the album's country.
struct SlideshowView: View {
    let album: Album
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var loadError = false
    @State private var showControls = false
    @State private var isPlaying = true
    @State private var scrubIndex: Double = 0
    @State private var isScrubbing = false
    @State private var advanceTask: Task<Void, Never>?
    @State private var hideControlsTask: Task<Void, Never>?

    @AppStorage("slideDuration") private var slideDuration: Double = 5
    @AppStorage("showsMiniMap") private var showsMiniMap = true

    private var items: [MediaItem] {
        album.items.sorted { $0.createdTime < $1.createdTime }
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
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .id(index)
            } else if loadError {
                ContentUnavailableView("Couldn’t load this item", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
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
        .onDisappear {
            advanceTask?.cancel()
            hideControlsTask?.cancel()
            player?.pause()
        }
    }

    // MARK: - Overlay

    private var overlayControls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if showsMiniMap, let coordinate = WorldGeometry.centroid(forCountryNamed: album.name) {
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
            Text("\(album.name) · \(index + 1)/\(items.count)")
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
                    in: 0...Double(items.count - 1),
                    step: 1
                ) { editing in
                    isScrubbing = editing
                    if !editing { advance(to: Int(scrubIndex)) }
                }
                .tint(.white)
            }

            HStack(spacing: 8) {
                durationMenu
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

    private var durationMenu: some View {
        Menu {
            Picker("Slide duration", selection: $slideDuration) {
                Text("2 s").tag(2.0)
                Text("5 s").tag(5.0)
                Text("8 s").tag(8.0)
                Text("15 s").tag(15.0)
            }
        } label: {
            Label("\(Int(slideDuration)) s", systemImage: "timer")
                .font(.subheadline.bold())
                .foregroundStyle(.white.opacity(0.9))
        }
        .onChange(of: slideDuration) {
            if isPlaying, player == nil { scheduleAdvance() }
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
        Map(initialPosition: .camera(MapCamera(centerCoordinate: coordinate, distance: 9_000_000))) {
            Marker(album.name, coordinate: coordinate)
                .tint(.orange)
        }
        .mapStyle(.imagery(elevation: .flat))
        .allowsHitTesting(false)
        .frame(width: 230, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .shadow(radius: 12)
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
        advanceTask?.cancel()
        advanceTask = Task { await show(index: newIndex) }
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
        loadError = false

        guard let url = try? await MediaCache.shared.file(for: (item.driveId, item.name)) else {
            loadError = true
            return
        }
        guard !Task.isCancelled else { return }

        if item.isVideo {
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
            withAnimation(.easeInOut(duration: 0.4)) {
                image = UIImage(contentsOfFile: url.path)
            }
            // Prefetch the next item while this one is on screen.
            if items.count > 1 {
                let next = items[(newIndex + 1) % items.count]
                Task.detached { _ = try? await MediaCache.shared.file(for: (next.driveId, next.name)) }
            }
            if isPlaying { scheduleAdvance() }
        }
    }
}
