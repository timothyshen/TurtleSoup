import Foundation

/// Build-time configuration constants.
///
/// Hardcoded rather than `@AppStorage` because the proxy URL is operator
/// concern, not user concern — end users don't see this and can't change
/// it. To point at a different deployment (staging, fork, etc), edit the
/// constant and rebuild.
///
/// Force-unwrapped URL on purpose: a malformed value here is a deploy
/// blunder we want to catch loudly at app launch, not silently produce a
/// "connection failed" toast for every user.
enum AppConfig {

    /// Vercel deployment of the haiguitang proxy. All Claude API calls go
    /// through here; we never let users supply their own Anthropic key.
    ///
    /// ⚠️ Replace this placeholder with the real URL once the proxy is
    /// deployed (B5). Until then the app can authenticate but every AI
    /// call (gameplay verdicts, puzzle generation, review) will fail.
    static let proxyBaseURL = URL(string: "https://CHANGE-ME.vercel.app")!
}
