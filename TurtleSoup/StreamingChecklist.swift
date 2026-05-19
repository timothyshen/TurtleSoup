import SwiftUI

// Reusable progress-checklist views for the streaming UIs.
//
// Both AI generation flows (puzzle drafting in AIPuzzleGeneratorSheet, post-
// game review in GameView.answerSheet) need the same visual pattern: an
// ordered list of expected fields where each row flips from a dim
// placeholder to a green checkmark + value preview as the proxy reports
// it closing. Extracting the rendering keeps the sheet/view code focused
// on the streaming state machine and unlocks SwiftUI previews of the
// checklist in isolation.
//
// Generic over the field schema — caller hands in an ordered list of
// (key, label) tuples plus the streamed values keyed by `field`.

struct StreamingChecklist: View {

    struct Row: Identifiable {
        /// Stable identifier across reorders. Same string the proxy uses
        /// in `progress.field`.
        let key: String
        /// Chinese label rendered to the user.
        let label: String
        /// Optional helper line shown when the row is still pending. Used
        /// for the review's `key_moments` row which doesn't get progress
        /// events — we explain why instead of looking broken.
        let pendingNote: String?

        var id: String { key }

        init(key: String, label: String, pendingNote: String? = nil) {
            self.key = key
            self.label = label
            self.pendingNote = pendingNote
        }
    }

    let rows: [Row]
    let streamedFields: [(field: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                StreamingChecklistRow(
                    label: row.label,
                    value: value(for: row.key),
                    pendingNote: row.pendingNote
                )
            }
        }
        .padding(14)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
    }

    private func value(for key: String) -> String? {
        streamedFields.first(where: { $0.field == key })?.value
    }
}

struct StreamingChecklistRow: View {

    let label: String
    /// When non-nil the row renders as completed (green checkmark + value).
    let value: String?
    /// Fallback caption when `value` is nil. Used by rows that won't ever
    /// receive a progress event (arrays, etc) so the user knows why.
    let pendingNote: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if value != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(value != nil ? .primary : .secondary)
                if let v = value {
                    Text(v)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                } else if let note = pendingNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Schema-specific row sets
//
// Centralized so the sheet/view and previews stay in sync. If the proxy
// adds a new field, update the list here once and both call sites and the
// preview catalog reflect it.

enum ChecklistSchemas {
    /// Fields the proxy emits progress for on /api/v1/generate-puzzle.
    /// Order mirrors what the model tends to fill first → last.
    static let puzzle: [StreamingChecklist.Row] = [
        .init(key: "title",      label: "标题"),
        .init(key: "difficulty", label: "难度"),
        .init(key: "scenario",   label: "汤面"),
        .init(key: "answer",     label: "汤底"),
        .init(key: "hint",       label: "提示"),
    ]

    /// Fields the proxy emits progress for on /api/v1/generate-review.
    /// `key_moments` is an array so it doesn't fire — we surface it as a
    /// row anyway with a pendingNote so the user understands the wait.
    static let review: [StreamingChecklist.Row] = [
        .init(key: "summary",     label: "总评"),
        .init(key: "key_moments", label: "关键时刻",
              pendingNote: "随完整结果一起返回"),
        .init(key: "tip",         label: "下次建议"),
    ]
}

// MARK: - Previews
//
// Three scenarios per schema: empty (nothing streamed yet), partial (one
// field landed), complete (all fields filled with realistic content).
// The dynamic UI elsewhere (spinner, error text) is rendered by the
// caller — these previews focus on the row-by-row appearance.

#Preview("Puzzle — empty") {
    StreamingChecklist(rows: ChecklistSchemas.puzzle, streamedFields: [])
        .padding()
        .frame(width: 400)
}

#Preview("Puzzle — partial") {
    StreamingChecklist(
        rows: ChecklistSchemas.puzzle,
        streamedFields: [
            (field: "title",      value: "公园里的湿长椅"),
            (field: "difficulty", value: "简单"),
        ]
    )
    .padding()
    .frame(width: 400)
}

#Preview("Puzzle — complete") {
    StreamingChecklist(
        rows: ChecklistSchemas.puzzle,
        streamedFields: [
            (field: "title",      value: "公园里的湿长椅"),
            (field: "difficulty", value: "简单"),
            (field: "scenario",   value: "李明清晨在公园散步，发现一条长椅是湿的，周围的地面和其他长椅却都是干的。"),
            (field: "answer",     value: "前一晚有一对情侣在长椅上看星星，女生因为感动哭了很久……"),
            (field: "hint",       value: "湿的来源不一定是雨"),
        ]
    )
    .padding()
    .frame(width: 400)
}

#Preview("Review — empty") {
    StreamingChecklist(rows: ChecklistSchemas.review, streamedFields: [])
        .padding()
        .frame(width: 400)
}

#Preview("Review — summary only") {
    StreamingChecklist(
        rows: ChecklistSchemas.review,
        streamedFields: [
            (field: "summary", value: "你用 8 轮锁定了真相。"),
        ]
    )
    .padding()
    .frame(width: 400)
}

#Preview("Review — full") {
    StreamingChecklist(
        rows: ChecklistSchemas.review,
        streamedFields: [
            (field: "summary", value: "你用 8 轮锁定了真相。"),
            (field: "tip",     value: "看到「同步」相关线索时先想物理可能性。"),
        ]
    )
    .padding()
    .frame(width: 400)
}
