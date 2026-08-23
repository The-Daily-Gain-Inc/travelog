import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var sync: SyncService
    @Environment(\.modelContext) private var modelContext
    @AppStorage("demoMode") private var demoMode = false
    @AppStorage("rootFolderName") private var rootFolderName = "Travelog"
    @Query private var albums: [Album]
    @State private var cacheSize: Int64 = 0

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
            .task { cacheSize = await MediaCache.shared.sizeOnDisk() }
        }
    }
}
