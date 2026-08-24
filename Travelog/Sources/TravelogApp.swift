import SwiftUI
import SwiftData
import GoogleSignIn
import AVFAudio
import BackgroundTasks

@main
struct TravelogApp: App {
    @StateObject private var auth = AuthService.shared
    @StateObject private var sync = SyncService()
    @Environment(\.scenePhase) private var scenePhase

    static let refreshTaskId = "ca.thedailygain.Travelog.refresh"

    static let container: ModelContainer = {
        try! ModelContainer(for: Album.self, MediaItem.self)
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
        }
        .modelContainer(Self.container)
        .onChange(of: scenePhase) { _, phase in
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

struct RootView: View {
    @EnvironmentObject private var auth: AuthService
    @AppStorage("demoMode") private var demoMode = false

    var body: some View {
        if auth.isRestoring && !demoMode {
            ProgressView()
        } else if auth.isSignedIn || demoMode {
            MainTabView()
        } else {
            LoginView()
        }
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
    @State private var ambientShow = false
    @State private var allItems: [MediaItem] = []

    var body: some View {
        content.task(id: auth.isSignedIn) {
            // A real account replaces the demo data entirely and syncs on arrival.
            if auth.isSignedIn {
                demoMode = false
                try? MockData.purge(from: modelContext)
                await sync.sync(rootFolderName: rootFolderName, context: modelContext)
                return
            }
            // Demo mode seeds itself if the sample albums aren't there yet.
            guard demoMode else { return }
            let albums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []
            if !albums.contains(where: { $0.driveId.hasPrefix(MockData.idPrefix) }) {
                try? MockData.seed(into: modelContext)
            }
        }
        // Ambient mode: any touch resets the idle clock; after the configured
        // quiet period the app turns into a photo frame.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onChanged { _ in lastInteraction = .now }
        )
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            guard ambientMode, !ambientShow,
                  Date.now.timeIntervalSince(lastInteraction) > ambientDelayMinutes * 60 else { return }
            let albums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []
            allItems = albums.flatMap(\.items)
            guard !allItems.isEmpty else { return }
            ambientShow = true
        }
        .fullScreenCover(isPresented: $ambientShow, onDismiss: { lastInteraction = .now }) {
            SlideshowView(
                title: String(localized: "Memories"),
                items: allItems,
                forceShuffle: true
            )
        }
    }

    // Selectable for UI automation via the -initialTab launch argument.
    @State private var selectedTab = UserDefaults.standard.string(forKey: "initialTab") ?? "slideshow"

    private var content: some View {
        TabView(selection: $selectedTab) {
            AlbumListView()
                .tabItem { Label("Slideshow", systemImage: "play.rectangle.on.rectangle") }
                .tag("slideshow")
            WorldMapView()
                .tabItem { Label("World Map", systemImage: "globe.europe.africa.fill") }
                .tag("map")
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag("stats")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
    }
}
