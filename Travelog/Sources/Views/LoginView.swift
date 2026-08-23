import SwiftUI
import SwiftData

struct LoginView: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.modelContext) private var modelContext
    @AppStorage("demoMode") private var demoMode = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "airplane.departure")
                    .font(.system(size: 90))
                    .foregroundStyle(.white)
                Text("Travelog")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Your travel photos, by country.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()

                Button {
                    Task {
                        do { try await auth.signIn() }
                        catch { errorMessage = error.localizedDescription }
                    }
                } label: {
                    Label("Sign in with Google", systemImage: "person.badge.key.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: 420)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.indigo)

                Button {
                    do {
                        try MockData.seed(into: modelContext)
                        demoMode = true
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Try with demo data", systemImage: "sparkles")
                        .font(.title3)
                        .frame(maxWidth: 420)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer().frame(height: 60)
            }
            .padding()
        }
    }
}
