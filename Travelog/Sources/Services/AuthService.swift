import Foundation
import GoogleSignIn
import UIKit

@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var user: GIDGoogleUser?
    @Published var isRestoring = true

    static let driveScope = "https://www.googleapis.com/auth/drive.readonly"

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
            hint: nil,
            additionalScopes: [Self.driveScope]
        )
        user = result.user
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        user = nil
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
