import Foundation
@testable import TurtleSoup

// Shared test fixtures used across multiple suites.
//
// Previously these helpers lived inside `ClaudeServiceTests.swift` marked
// `private`, which silently meant they were only visible within that file.
// `GameViewModelTests.swift` referenced them anyway and would have failed
// to compile on the actual build (SourceKit cross-file index is too lossy
// to surface this in the harness). Hoisting them here, internal-scoped,
// fixes that AND removes per-suite duplication.

// MARK: - Puzzle fixture

func samplePuzzle() -> Puzzle {
    Puzzle(
        id: UUID(),
        title: "测试题",
        difficulty: .medium,
        scenario: "汤面",
        answer: "汤底关键真相",
        hint: nil,
        author: "测试",
        playCount: 0
    )
}

// MARK: - Non-streaming Claude API envelopes
//
// Format: `{"content": [{"text": "..."}]}` — the shape ClaudeService.send()
// expects when stream=false. Tests against the non-streaming path use these.

/// Build the outer envelope `{content: [{text: "..."}]}` with arbitrary text.
func anthropicEnvelope(text: String) -> Data {
    let env: [String: Any] = ["content": [["text": text]]]
    return try! JSONSerialization.data(withJSONObject: env)
}

/// Convenience for the common case where `text` is a verdict+comment JSON.
func anthropicSuccessBody(verdict: String, comment: String) -> Data {
    let inner = #"{"verdict":"\#(verdict)","comment":"\#(comment)"}"#
    return anthropicEnvelope(text: inner)
}

// MARK: - SSE / streaming envelopes
//
// Format: text/event-stream chunked output that ClaudeService.sendStream
// consumes via URLSession.bytes.lines + JSON-per-data-line parsing.
//
// The bytes shape we deliver matches Anthropic's documented event stream
// closely enough that the parser exercises the same code paths as a real
// upstream connection. We emit:
//
//   event: message_start
//   data: {"type":"message_start"}
//
//   event: content_block_delta
//   data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}
//
//   event: message_stop
//   data: {"type":"message_stop"}
//
// Trailing blank line separates each event per the SSE spec; the URLSession
// line iterator surfaces both "data: ..." lines and the empties (which the
// parser skips because they don't start with "data: ").

/// SSE body that delivers a verdict+comment JSON in a single text_delta.
///
/// Use for tests that don't care about chunking — they just want the
/// streaming path to produce the expected final state.
func anthropicSSEBody(verdict: String, comment: String) -> Data {
    let inner = #"{"verdict":"\#(verdict)","comment":"\#(comment)"}"#
    return sseEvents([
        ("message_start",        #"{"type":"message_start"}"#),
        ("content_block_delta",  contentBlockDelta(text: inner)),
        ("message_stop",         #"{"type":"message_stop"}"#),
    ])
}

/// SSE body that splits the verdict+comment JSON across multiple deltas.
/// Useful for asserting verdict early-emission lands before the full
/// payload arrives.
///
/// `firstChunk` should be a prefix that contains the closed verdict field
/// (e.g. `{"verdict":"yes","comment":"`); `secondChunk` carries the rest.
func anthropicSSEChunkedBody(firstChunk: String, secondChunk: String) -> Data {
    sseEvents([
        ("message_start",        #"{"type":"message_start"}"#),
        ("content_block_delta",  contentBlockDelta(text: firstChunk)),
        ("content_block_delta",  contentBlockDelta(text: secondChunk)),
        ("message_stop",         #"{"type":"message_stop"}"#),
    ])
}

// MARK: - SSE construction helpers

private func contentBlockDelta(text: String) -> String {
    // JSON-escape the text so quotes inside the verdict/comment don't
    // collapse the outer event payload.
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"\#(escaped)"}}"#
}

private func sseEvents(_ events: [(name: String, data: String)]) -> Data {
    var out = ""
    for (name, data) in events {
        out += "event: \(name)\n"
        out += "data: \(data)\n\n"
    }
    return Data(out.utf8)
}
