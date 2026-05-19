// Wire format for the simplified SSE we emit to clients from streaming
// endpoints (generate-puzzle, generate-review). Anthropic's upstream SSE
// is consumed and translated; clients see only this narrower shape.
//
// Three event types:
//   progress — a top-level field of the tool input finished streaming
//   complete — final assembled object
//   error    — fatal failure mid-stream
//
// All payloads are JSON. The Swift client mirrors this in
// {Puzzle,Review}GenerationService streaming variants.

export type ServerSentEvent =
  | { name: "progress"; data: { field: string; value: string } }
  | { name: "complete"; data: Record<string, unknown> }
  | { name: "error";    data: { code: string; message: string } }
  /// Anthropic returned stop_reason: "refusal". Distinct from "error" so
  /// the client can render a non-alarming "AI 拒绝处理" notice instead
  /// of treating it as a transient failure to retry.
  | { name: "refusal";  data: { category?: string; explanation?: string } };
