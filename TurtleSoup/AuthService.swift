import Foundation
import FirebaseAuth
import AuthenticationServices
import CryptoKit
import Observation

@Observable
@MainActor
final class AuthService: NSObject {

    private(set) var user: FirebaseAuth.User? = nil
    private var currentNonce: String?

    override init() {
        super.init()
        user = Auth.auth().currentUser
        // Discard the returned handle — we never remove this listener because
        // it lives for the lifetime of the app singleton anyway.
        _ = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.user = user }
        }
    }

    var isSignedIn: Bool { user != nil }
    var displayName: String { user?.displayName ?? user?.email ?? "未登录" }
    /// Convenience for call sites that just want the uid without having to
    /// `import FirebaseAuth` to access `user.uid`. Swift's strict module
    /// imports otherwise require every file that touches `user.uid` to
    /// import the Firebase module too.
    var uid: String? { user?.uid }

    // MARK: - Email / Password

    func signIn(email: String, password: String) async throws {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        user = result.user
    }

    func signUp(email: String, password: String) async throws {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        user = result.user
    }

    func signOut() throws {
        try Auth.auth().signOut()
        user = nil
    }

    /// Fetch a fresh Firebase ID Token for the currently signed-in user.
    /// Used by `ClaudeService.Transport.proxy` to authenticate proxy requests.
    /// Throws `AuthError.notSignedIn` if no user is signed in.
    func getIDToken() async throws -> String {
        guard let user else { throw AuthError.notSignedIn }
        return try await user.getIDToken()
    }

    // MARK: - Apple Sign In

    func startAppleSignIn() -> ASAuthorizationAppleIDRequest {
        let nonce = randomNonce()
        currentNonce = nonce
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
        return request
    }

    func handleAppleSignIn(result: Result<ASAuthorization, Error>) async throws {
        switch result {
        case .failure(let error):
            throw error
        case .success(let auth):
            // Consume nonce immediately to prevent stale-nonce reuse on concurrent flows
            let nonce = currentNonce
            currentNonce = nil
            guard
                let nonce,
                let appleCredential = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = appleCredential.identityToken,
                let token = String(data: tokenData, encoding: .utf8)
            else { throw AuthError.invalidCredential }

            let credential = OAuthProvider.appleCredential(
                withIDToken: token,
                rawNonce: nonce,
                fullName: appleCredential.fullName
            )
            let firebaseResult = try await Auth.auth().signIn(with: credential)
            user = firebaseResult.user
        }
    }

    // MARK: - Helpers

    private func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(length)
            .description
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    enum AuthError: LocalizedError {
        case invalidCredential
        case notSignedIn
        var errorDescription: String? {
            switch self {
            case .invalidCredential: return "无效的 Apple 登录凭证"
            case .notSignedIn:       return "未登录"
            }
        }
    }
}
