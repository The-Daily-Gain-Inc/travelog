import SwiftUI
import AVKit

/// Fullscreen slideshow of an album's photos and videos. Status bar and home
/// indicator are hidden; photos auto-advance, videos play through to the end.
struct SlideshowView: View {
    let album: Album
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var loadError = false
    @State private var showControls = false
    @State private var advanceTask: Task<Void, Never>?

    private var items: [MediaItem] {
        album.items.sorted { $0.createdTime < $1.createdTime }
    }

    private let photoDuration: UInt64 = 5_000_000_000

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
        .onTapGesture { withAnimation { showControls.toggle() } }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.width < 0 { advance(by: 1) } else { advance(by: -1) }
            }
        )
        .task { await show(index: 0) }
        .onDisappear {
            advanceTask?.cancel()
            player?.pause()
        }
    }

    private var overlayControls: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Text("\(album.name) · \(index + 1)/\(items.count)")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(24)
            Spacer()
        }
        .transition(.opacity)
    }

    private func advance(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = (index + delta + items.count) % items.count
        advanceTask?.cancel()
        advanceTask = Task { await show(index: next) }
    }

    private func show(index newIndex: Int) async {
        guard !items.isEmpty else { loadError = true; return }
        index = newIndex
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
            p.play()
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
            advanceTask = Task {
                try? await Task.sleep(nanoseconds: photoDuration)
                guard !Task.isCancelled else { return }
                advance(by: 1)
            }
        }
    }
}
