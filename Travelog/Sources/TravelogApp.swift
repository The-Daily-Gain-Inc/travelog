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
    var body: some View {
        TabView {
            AlbumListView()
                .tabItem { Label("Slideshow", systemImage: "play.rectangle.on.rectangle") }
            WorldMapView()
                .tabItem { Label("World Map", systemImage: "globe.europe.africa.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
