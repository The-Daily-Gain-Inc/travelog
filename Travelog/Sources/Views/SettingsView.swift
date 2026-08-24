import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var sync: SyncService
    @Environment(\.modelContext) private var modelContext
    @AppStorage("demoMode") private var demoMode = false
    @AppStorage("rootFolderName") private var rootFolderName = "Travelog"
    @AppStorage("displayMaxPixel") private var displayMaxPixel: Double = 0
    @AppStorage("kenBurns") private var kenBurns = true
    @AppStorage("showCaptions") private var showCaptions = true
    @AppStorage("shuffleSlides") private var shuffleSlides = false
    @AppStorage("skipLivePhotos") private var skipLivePhotos = true
    @AppStorage("showHiddenItems") private var showHiddenItems = false
    @AppStorage("transitionStyle") private var transitionStyle = "fade"
    @AppStorage("muteVideos") private var muteVideos = false
    @AppStorage("accentTheme") private var accentTheme = "orange"
    @AppStorage("dailyMemoryNotification") private var dailyMemoryNotification = false
    @AppStorage("videoLimitSeconds") private var videoLimitSeconds: Double = 0
    @AppStorage("sleepTimerMinutes") private var sleepTimerMinutes: Double = 0
    @AppStorage("cacheLimitMB") private var cacheLimitMB: Double = 0
    @State private var exportURL: URL?
    @AppStorage("showTripLines") private var showTripLines = true
    @AppStorage("ambientMode") private var ambientMode = false
    @AppStorage("ambientDelayMinutes") private var ambientDelayMinutes = 5.0
    @Query private var albums: [Album]
    @State private var cacheSize: Int64 = 0
    @ObservedObject private var localLibrary = LocalLibrary.shared
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Google Drive") {
                    if demoMode && !auth.isSignedIn {
                        Label("Demo mode — using sample data", systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                    } else if let profile = auth.user?.profile {
                        LabeledContent("Account", value: profile.email)
                    }
                    TextField("Drive folder name", text: $rootFolderName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button {
                        Task { await sync.sync(rootFolderName: rootFolderName, context: modelContext) }
                    } label: {
                        if sync.isSyncing {
                            HStack {
                                ProgressView()
                                Text(sync.progressText ?? String(localized: "Syncing…"))
                            }
                        } else {
                            Label("Synchronize Albums", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(sync.isSyncing || !auth.isSignedIn)

                    if !auth.isSignedIn {
                        Text("Sign in with Google to sync your Drive albums.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let error = sync.lastError {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section {
                    if let name = localLibrary.libraryName {
                        LabeledContent("Connected folder", value: name)
                        Button {
                            Task { await localLibrary.rescan(context: modelContext) }
                        } label: {
                            if localLibrary.isScanning {
                                HStack { ProgressView(); Text("Scanning…") }
                            } else {
                                Label("Rescan Drive", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(localLibrary.isScanning)
                        Button("Remove External Albums", role: .destructive) {
                            localLibrary.remove(context: modelContext)
                        }
                    } else {
                        Button {
                            showFolderPicker = true
                        } label: {
                            Label("Connect USB Drive Folder…", systemImage: "externaldrive.badge.plus")
                        }
                    }
                    if let error = localLibrary.lastError {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                } header: {
                    Text("External Storage")
                } footer: {
                    Text("Pick a folder on a connected SSD or SD card. Each subfolder becomes a country album, alongside your Drive albums. Media plays while the drive is attached (or after it's cached).")
                }

                Section("Slideshow") {
                    Picker("Photo resolution", selection: $displayMaxPixel) {
                        Text("Original").tag(0.0)
                        Text("4K").tag(3840.0)
                        Text("2K").tag(2048.0)
                        Text("HD").tag(1280.0)
                    }
                    Picker("Transition", selection: $transitionStyle) {
                        Text("Fade").tag("fade")
                        Text("Slide").tag("slide")
                        Text("Zoom").tag("zoom")
                    }
                    Toggle("Ken Burns effect", isOn: $kenBurns)
                    Toggle("Mute videos", isOn: $muteVideos)
                    Picker("Limit videos to", selection: $videoLimitSeconds) {
                        Text("Full length").tag(0.0)
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                    }
                    Picker("Sleep timer", selection: $sleepTimerMinutes) {
                        Text("Off").tag(0.0)
                        Text("15 minutes").tag(15.0)
                        Text("30 minutes").tag(30.0)
                        Text("1 hour").tag(60.0)
                    }
                    Toggle("Captions (place & date)", isOn: $showCaptions)
                    Toggle("Shuffle", isOn: $shuffleSlides)
                    Toggle("Skip Live Photo clips", isOn: $skipLivePhotos)
                    Toggle("Show hidden items in grids", isOn: $showHiddenItems)
                }

                Section {
                    Toggle("Photo Frame mode", isOn: $ambientMode)
                    if ambientMode {
                        Picker("Start after", selection: $ambientDelayMinutes) {
                            Text("1 minute").tag(1.0)
                            Text("5 minutes").tag(5.0)
                            Text("15 minutes").tag(15.0)
                            Text("30 minutes").tag(30.0)
                        }
                    }
                } header: {
                    Text("Photo Frame")
                } footer: {
                    Text("When idle, the app starts a World Tour on the map — flying to each country and playing its photos — and keeps the screen awake.")
                }

                Section("Map") {
                    Toggle("Trip lines between photos", isOn: $showTripLines)
                }

                Section("Appearance") {
                    Picker("Accent color", selection: $accentTheme) {
                        Text("Orange").tag("orange")
                        Text("Blue").tag("blue")
                        Text("Green").tag("green")
                        Text("Pink").tag("pink")
                        Text("Teal").tag("teal")
                    }
                }

                Section {
                    Toggle("Daily memories reminder", isOn: $dailyMemoryNotification)
                        .onChange(of: dailyMemoryNotification) {
                            if dailyMemoryNotification {
                                Task {
                                    if await !MemoriesNotifications.enable() {
                                        dailyMemoryNotification = false
                                    }
                                }
                            } else {
                                MemoriesNotifications.disable()
                            }
                        }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("A gentle nudge at 9 AM to revisit photos taken on this day in past years.")
                }

                Section("Library") {
                    LabeledContent("Albums", value: "\(albums.count)")
                    LabeledContent("Media items", value: "\(albums.reduce(0) { $0 + $1.items.count })")
                    LabeledContent("Cache size", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    Picker("Cache limit", selection: $cacheLimitMB) {
                        Text("Unlimited").tag(0.0)
                        Text("500 MB").tag(500.0)
                        Text("2 GB").tag(2048.0)
                        Text("10 GB").tag(10240.0)
                    }
                    .onChange(of: cacheLimitMB) {
                        guard cacheLimitMB > 0 else { return }
                        Task {
                            await MediaCache.shared.enforceLimit(maxBytes: Int64(cacheLimitMB * 1_048_576))
                            cacheSize = await MediaCache.shared.sizeOnDisk()
                        }
                    }
                    Button("Clear Media Cache", role: .destructive) {
                        Task {
                            await MediaCache.shared.clear()
                            cacheSize = await MediaCache.shared.sizeOnDisk()
                        }
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share Exported Data", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            exportLibrary()
                        } label: {
                            Label("Export Library Data", systemImage: "doc.badge.arrow.up")
                        }
                    }
                }

                Section {
                    if demoMode {
                        Button("Exit Demo Mode", role: .destructive) {
                            demoMode = false
                        }
                    }
                    if auth.isSignedIn {
                        Button("Sign Out", role: .destructive) {
                            auth.signOut()
                            demoMode = false
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Task { await localLibrary.connect(url: url, context: modelContext) }
                }
            }
            .task { cacheSize = await MediaCache.shared.sizeOnDisk() }
        }
    }

    /// Writes albums/items metadata (never the media itself) as JSON.
    private func exportLibrary() {
        var albumsJSON: [[String: Any]] = []
        for album in albums {
            let items: [[String: Any]] = album.items.map { item in
                var dict: [String: Any] = [
                    "name": item.name,
                    "mimeType": item.mimeType,
                    "createdTime": item.createdTime.ISO8601Format(),
                    "sizeBytes": item.sizeBytes,
                    "favorite": item.isFavorite,
                    "hidden": item.isHidden,
                ]
                if let lat = item.latitude, let lon = item.longitude {
                    dict["latitude"] = lat
                    dict["longitude"] = lon
                }
                return dict
            }
            albumsJSON.append(["country": album.name, "items": items])
        }
        let payload: [String: Any] = ["exported": Date.now.ISO8601Format(), "albums": albumsJSON]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Travelog-Export.json")
        try? data.write(to: url)
        exportURL = url
    }
}
