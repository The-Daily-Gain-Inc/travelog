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
                    Toggle("Ken Burns effect", isOn: $kenBurns)
                    Toggle("Captions (place & date)", isOn: $showCaptions)
                    Toggle("Shuffle", isOn: $shuffleSlides)
                    Toggle("Skip Live Photo clips", isOn: $skipLivePhotos)
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
                    Text("When idle, the app starts a shuffled slideshow of all your memories and keeps the screen awake.")
                }

                Section("Map") {
                    Toggle("Trip lines between photos", isOn: $showTripLines)
                }

                Section("Library") {
                    LabeledContent("Albums", value: "\(albums.count)")
                    LabeledContent("Media items", value: "\(albums.reduce(0) { $0 + $1.items.count })")
                    LabeledContent("Cache size", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    Button("Clear Media Cache", role: .destructive) {
                        Task {
                            await MediaCache.shared.clear()
                            cacheSize = await MediaCache.shared.sizeOnDisk()
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
}
