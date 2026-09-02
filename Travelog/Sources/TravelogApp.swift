import SwiftUI
import SwiftData
import GoogleSignIn
import AVFAudio
import BackgroundTasks

/// Routes newly connecting scenes: external displays (AirPlay screens,
/// HDMI) get a non-interactive shuffled slideshow of the whole library.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            config.delegateClass = ExternalSceneDelegate.self
        }
        return config
    }
}

final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let items = ((try? TravelogApp.container.mainContext.fetch(FetchDescriptor<MediaItem>())) ?? [])
            .filter { !$0.isHidden }
        let root = SlideshowView(
            title: String(localized: "Memories"),
            items: items,
            forceShuffle: true
        )
        .modelContainer(TravelogApp.container)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: root)
        self.window = window
        window.makeKeyAndVisible()
    }
}

@main
struct TravelogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthService.shared
    @StateObject private var sync = SyncService()
    @Environment(\.scenePhase) private var scenePhase

    static let refreshTaskId = "ca.thedailygain.Travelog.refresh"

    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: Album.self, MediaItem.self)
        } catch {
            // Schema drift or a corrupt store: wipe and start fresh rather
            // than crash-looping — the library re-syncs from Drive.
            let stores = URL.applicationSupportDirectory
            for name in ["default.store", "default.store-shm", "default.store-wal"] {
                try? FileManager.default.removeItem(at: stores.appendingPathComponent(name))
            }
            return try! ModelContainer(for: Album.self, MediaItem.self)
        }
    }()

    init() {
        // Mix with whatever the user is already playing (Music, podcasts) so a
        // slideshow never interrupts their soundtrack.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            Self.handleBackgroundRefresh(task as! BGAppRefreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(sync)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                .task { await auth.restore() }
                .task {
                    let limitMB = UserDefaults.standard.double(forKey: "cacheLimitMB")
                    if limitMB > 0 {
                        await MediaCache.shared.enforceLimit(maxBytes: Int64(limitMB * 1_048_576))
                    }
                }
        }
        .modelContainer(Self.container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await WidgetPublisher.publish(context: Self.container.mainContext) }
            }
            if phase == .background { Self.scheduleBackgroundRefresh() }
        }
    }

    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let work = Task { @MainActor in
            guard AuthService.shared.isSignedIn || GIDSignIn.sharedInstance.hasPreviousSignIn() else {
                task.setTaskCompleted(success: true)
                return
            }
            if !AuthService.shared.isSignedIn { await AuthService.shared.restore() }
            let folder = UserDefaults.standard.string(forKey: "rootFolderName") ?? "Travelog"
            let service = SyncService()
            await service.sync(rootFolderName: folder, context: container.mainContext)
            task.setTaskCompleted(success: service.lastError == nil)
        }
        task.expirationHandler = { work.cancel() }
    }
}

/// Reports every window touch without ever claiming it (recognizer fails
/// immediately and doesn't cancel touches), so controls behave normally.
struct TouchObserver: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? HostView)?.onTouch = onTouch
    }

    final class HostView: UIView {
        var onTouch: (() -> Void)?
        private weak var recognizer: UIGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard recognizer == nil, let window else { return }
            let r = Recognizer()
            r.onTouch = { [weak self] in self?.onTouch?() }
            r.cancelsTouchesInView = false
            r.delaysTouchesBegan = false
            r.delaysTouchesEnded = false
            window.addGestureRecognizer(r)
            recognizer = r
        }
    }

    final class Recognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var onTouch: (() -> Void)?

        init() {
            super.init(target: nil, action: nil)
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch?()
            state = .failed
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var auth: AuthService
    @AppStorage("demoMode") private var demoMode = false
    // Referenced so accent changes re-render the whole tree immediately.
    @AppStorage("accentTheme") private var accentTheme = "orange"
    @AppStorage("appearance") private var appearance = "system"

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        Group {
            if auth.isRestoring && !demoMode {
                ProgressView()
            } else if auth.isSignedIn || demoMode {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .tint(Color.appAccent)
        .preferredColorScheme(colorScheme)
        .id(accentTheme)
    }
}

struct MainTabView: View {
    @AppStorage("demoMode") private var demoMode = false
    @AppStorage("rootFolderName") private var rootFolderName = "Travelog"
    @AppStorage("ambientMode") private var ambientMode = false
    @AppStorage("ambientDelayMinutes") private var ambientDelayMinutes = 5.0
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var sync: SyncService
    @State private var lastInteraction = Date.now

    var body: some View {
        content.task(id: auth.isSignedIn) {
            // A real account replaces the demo data entirely and syncs on arrival.
            if auth.isSignedIn {
                demoMode = false
                try? MockData.purge(from: modelContext)
                await sync.sync(rootFolderName: rootFolderName, context: modelContext)
                if UserDefaults.standard.bool(forKey: "prewarmThumbnails") {
                    let albums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []
                    DownloadManager.shared.prewarmThumbnails(albums: albums)
                }
                return
            }
            // Demo mode seeds itself if the sample albums are missing or
            // predate a schema addition (e.g. photo GPS) and need refreshing.
            guard demoMode else { return }
            let albums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []
            let mocks = albums.filter { $0.driveId.hasPrefix(MockData.idPrefix) }
            if mocks.isEmpty || mocks.contains(where: { album in album.items.contains { $0.latitude == nil } }) {
                try? MockData.seed(into: modelContext)
            }
        }
        // Ambient mode: any touch resets the idle clock; after the configured
        // quiet period the app turns into a photo frame. The observer watches
        // window touches passively — a gesture here would fight the controls.
        .background(TouchObserver { lastInteraction = .now })
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            // Idle Photo Frame = the map's World Tour: hop the globe country
            // by country, playing each album through.
            guard ambientMode, !TourController.shared.isTouring,
                  Date.now.timeIntervalSince(lastInteraction) > ambientDelayMinutes * 60 else { return }
            let albums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []
            guard albums.contains(where: { !$0.items.isEmpty }) else { return }
            lastInteraction = .now
            selectedTab = "map"
            TourController.shared.tourRequested = true
        }
        .onReceive(TourController.shared.$focusAlbumId) { id in
            if id != nil { selectedTab = "map" }
        }
        .onChange(of: selectedTab) {
            UserDefaults.standard.set(selectedTab, forKey: "lastTab")
        }
    }

    // Selectable for UI automation via the -initialTab launch argument;
    // otherwise the last-used tab is restored.
    @State private var selectedTab = UserDefaults.standard.string(forKey: "initialTab")
        ?? UserDefaults.standard.string(forKey: "lastTab")
        ?? "slideshow"

    private var content: some View {
        TabView(selection: $selectedTab) {
            AlbumListView()
                .tabItem { Label("Albums", systemImage: "photo.stack") }
                .tag("slideshow")
            LibraryView()
                .tabItem { Label("Photos", systemImage: "square.grid.3x3.fill") }
                .tag("photos")
            WorldMapView()
                .tabItem { Label("World Map", systemImage: "globe.europe.africa.fill") }
                .tag("map")
            TripsView()
                .tabItem { Label("Trips", systemImage: "airplane") }
                .tag("trips")
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag("stats")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
    }
}
