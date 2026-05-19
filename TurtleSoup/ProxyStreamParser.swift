import Foundation

/// Parses the simplified SSE wire format we emit from `proxy/api/v1/generate-*`
/// endpoints when the caller opts into streaming (`stream: true` in body).
///
/// Format:
///   event: progress
///   data: {"field": "title", "value": "..."}
///
///   event: complete
///   data: {"puzzle": {...}}      // or {"review": {...}}
///
///   event: error
///   data: {"code": "...", "message": "..."}
///
/// This is intentionally narrower than Anthropic's native SSE — clients
/// only need to handle three event types, and the heavy lifting (partial
/// JSON extraction, field-close detection) happens server-side.
enum ProxyStreamEvent: Equatable {
    case progress(field: String, value: String)
    /// Decoded body of the `complete` event. Caller drills into specific
    /// keys (`puzzle`, `review`) using its known schema.
    case complete(payload: [String: Any])
    case error(code: String, message: String)
    /// Anthropic returned stop_reason: "refusal". Distinct from `.error`
    /// so callers can render a non-alarming "AI 拒绝处理" UI without
    /// looking like a transient bug to retry.
    case refusal(category: String?, explanation: String?)

    static func == (lhs: ProxyStreamEvent, rhs: ProxyStreamEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.progress(la, lv), .progress(ra, rv)): return la == ra && lv == rv
        case let (.error(la, lm),    .error(ra, rm)):    return la == ra && lm == rm
        case let (.refusal(lc, le),  .refusal(rc, re)):  return lc == rc && le == re
        // [String: Any] isn't Equatable; treat as opaque — equality only
        // makes sense via direct field comparison by the caller.
        case (.complete, .complete): return false
        default: return false
        }
    }
}

/// Reads SSE event blocks off a URLSession byte stream and emits structured
/// events. Centralizes the "wait for blank line, parse event:/data:" loop
/// so PuzzleGenerationService and ReviewService don't duplicate it.
struct ProxyStreamReader {

    /// Stream events from `bytes`. Caller is responsible for having
    /// already validated the HTTP status (this iterator assumes 200).
    static func events(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<ProxyStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var currentEvent = ""
                    var dataLines: [String] = []

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.isEmpty {
                            // Blank line = end of an SSE block. Process if we
                            // have a data payload; reset for next event.
                            if !dataLines.isEmpty {
                                if let event = parseEvent(name: currentEvent, dataJSON: dataLines.joined(separator: "\n")) {
                                    continuation.yield(event)
                                }
                            }
                            currentEvent = ""
                            dataLines.removeAll(keepingCapacity: true)
                            continue
                        }
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data: ") {
                            dataLines.append(String(line.dropFirst(6)))
                        }
                        // Unknown lines (comments, retry, id) are ignored.
                    }
                    // Trailing block without a final blank line.
                    if !dataLines.isEmpty,
                       let event = parseEvent(name: currentEvent, dataJSON: dataLines.joined(separator: "\n")) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func parseEvent(name: String, dataJSON: String) -> ProxyStreamEvent? {
        guard let data = dataJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        switch name {
        case "progress":
            guard let field = obj["field"] as? String,
                  let value = obj["value"] as? String else { return nil }
            return .progress(field: field, value: value)
        case "complete":
            return .complete(payload: obj)
        case "error":
            let code = (obj["code"] as? String) ?? "stream_error"
            let message = (obj["message"] as? String) ?? "unknown"
            return .error(code: code, message: message)
        case "refusal":
            return .refusal(
                category: obj["category"] as? String,
                explanation: obj["explanation"] as? String
            )
        default:
            return nil
        }
    }
}
