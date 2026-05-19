import Foundation

/// One-shot silent retry around `URLSession.bytes(for:)`.
///
/// Used by every streaming service (`ClaudeService.sendStream`,
/// `PuzzleGenerationService.generateStream`, `ReviewService.generateStream`)
/// to absorb transient connection blips that fire BEFORE any data arrives.
/// Network drop after the first byte is intentionally not retried — the
/// upstream model has already produced state we can't reconstruct, so we
/// surface the error and let the UI's retry button drive a fresh attempt
/// (P2-4 added those buttons everywhere).
///
/// Worth a single retry because the alternative — surfacing every flaky-
/// Wi-Fi failure to the user — is noisy and unactionable. After two
/// connection attempts though, we give up: real outages should fail loud.
enum SessionRetry {

    /// Default 500ms backoff. Long enough that a routing/DNS hiccup has
    /// time to clear, short enough that the user doesn't notice. Caller
    /// can override for tests.
    static func bytesWithRetry(
        for request: URLRequest,
        session: URLSession,
        delay: UInt64 = 500_000_000
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: request)
        } catch let e as URLError where isTransient(e) {
            try await Task.sleep(nanoseconds: delay)
            return try await session.bytes(for: request)
        }
    }

    /// Error codes that justify a silent retry. Deliberately tight — we
    /// don't retry 4xx-equivalent failures or auth issues; those should
    /// surface as-is so the user can act.
    private static func isTransient(_ e: URLError) -> Bool {
        switch e.code {
        case .networkConnectionLost,
             .timedOut,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .dataNotAllowed,
             .dnsLookupFailed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}
