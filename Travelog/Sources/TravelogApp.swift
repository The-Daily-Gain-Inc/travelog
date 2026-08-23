import SwiftUI
import SwiftData
import GoogleSignIn

@main
struct TravelogApp: App {
    @StateObject private var auth = AuthService.shared
    @StateObject private var sync = SyncService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(sync)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                .task { await auth.restore() }
        }
        .modelContainer(for: [Album.self, MediaItem.self])
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
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        content.task {
            // Demo mode seeds itself if the sample albums aren't there yet.
            guard demoMode else { return }
            let albums = (try? modelContext.fetch(FetchDescriptor<Album>())) ?? []
            if !albums.contains(where: { $0.driveId.hasPrefix(MockData.idPrefix) }) {
                try? MockData.seed(into: modelContext)
            }
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
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
    }
}
