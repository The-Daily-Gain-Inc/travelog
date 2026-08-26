import Foundation
import GoogleSignIn
import UIKit

@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var user: GIDGoogleUser?
    @Published var isRestoring = true

    static let driveScope = "https://www.googleapis.com/auth/drive.readonly"

    /// Last account that signed in on this device — used only as a sheet
    /// pre-fill hint. Never shipped in the binary; lives in local defaults.
    private static let lastAccountKey = "lastSignedInEmail"

    static var accountHint: String? {
        UserDefaults.standard.string(forKey: lastAccountKey)
    }

    var isSignedIn: Bool { user != nil }

    func restore() async {
        defer { isRestoring = false }
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        user = try? await GIDSignIn.sharedInstance.restorePreviousSignIn()
    }

    func signIn() async throws {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
            .first else { return }
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: root,
            hint: Self.accountHint,
            additionalScopes: [Self.driveScope]
        )
        user = result.user
        if let email = result.user.profile?.email {
            UserDefaults.standard.set(email, forKey: Self.lastAccountKey)
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        user = nil
        UserDefaults.standard.removeObject(forKey: Self.lastAccountKey)
    }

    /// Fresh bearer token for Drive REST calls, refreshing if needed.
    func accessToken() async throws -> String {
        guard let user else { throw URLError(.userAuthenticationRequired) }
        // Re-request the Drive scope if it was not granted.
        if !(user.grantedScopes ?? []).contains(Self.driveScope) {
            try await signIn()
        }
        try await user.refreshTokensIfNeeded()
        return user.accessToken.tokenString
    }
}
