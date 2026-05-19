// Streaming helpers for Anthropic tool_use responses.
//
// Anthropic emits tool inputs as a series of `input_json_delta` events,
// each carrying a fragment of the final JSON. We accumulate those fragments
// server-side and detect when individual fields close so we can forward
// simplified progress events to the client.
//
// Why server-side detection: clients would otherwise need their own partial
// JSON parser. Doing it once at the proxy keeps the Swift code small and
// shields it from Anthropic protocol changes.

import type { ServerSentEvent } from "./sse-shape.js";

/**
 * Detects newly-closed string fields in a streaming JSON buffer.
 *
 * Tracks which top-level string keys have been emitted so each fires at
 * most once even though the regex scan re-runs every push. Numeric / enum
 * fields aren't tracked separately — Anthropic emits enums as strings, and
 * we don't care about numbers for puzzle/review schemas.
 */
export class FieldDetector {
  private buffer = "";
  private emitted = new Set<string>();
  private readonly fields: Set<string>;

  /**
   * @param fields Known top-level fields to watch for. Constraining the
   *   key alphabet keeps the regex tight and avoids false positives on
   *   strings that happen to contain `"foo":"bar"` substrings.
   */
  constructor(fields: readonly string[]) {
    this.fields = new Set(fields);
  }

  /**
   * Append `chunk` to the internal buffer and return any fields that
   * newly closed.
   */
  push(chunk: string): Array<{ field: string; value: string }> {
    this.buffer += chunk;
    const out: Array<{ field: string; value: string }> = [];

    // Match `"key":"value"` where value tolerates escaped quotes (\")
    // and backslashes (\\). Lazy quantifier so we stop at the first
    // unescaped closing quote.
    const re = /"([a-z_]+)"\s*:\s*"((?:[^"\\]|\\.)*)"/g;
    for (const match of this.buffer.matchAll(re)) {
      const field = match[1]!;
      const rawValue = match[2]!;
      if (!this.fields.has(field) || this.emitted.has(field)) continue;
      this.emitted.add(field);
      out.push({ field, value: unescapeJSON(rawValue) });
    }
    return out;
  }

  /** Full accumulated buffer — call after message_stop to parse the final JSON. */
  full(): string {
    return this.buffer;
  }
}

function unescapeJSON(s: string): string {
  // We capture the raw match-2 contents which still contain JSON escapes.
  // Parsing via JSON.parse on `"<s>"` is the cheapest way to unescape.
  try {
    return JSON.parse(`"${s}"`);
  } catch {
    return s;
  }
}

/**
 * Build one SSE chunk from an event name + JSON-serializable payload.
 *
 * Format matches what Anthropic emits (and what our streaming client
 * already parses): `event: <name>\ndata: <json>\n\n`.
 */
export function sseEvent(event: ServerSentEvent): string {
  return `event: ${event.name}\ndata: ${JSON.stringify(event.data)}\n\n`;
}

/**
 * Parse one SSE block (everything between two blank lines) into
 * `{event, data}` form. Returns null on malformed input.
 *
 * Used by the proxy to consume Anthropic's upstream stream.
 */
export function parseSSEBlock(block: string): { event: string; data: unknown } | null {
  const lines = block.split("\n");
  let eventName = "";
  const dataParts: string[] = [];
  for (const line of lines) {
    if (line.startsWith("event: ")) eventName = line.slice(7).trim();
    else if (line.startsWith("data: ")) dataParts.push(line.slice(6));
  }
  if (!dataParts.length) return null;
  try {
    return { event: eventName, data: JSON.parse(dataParts.join("\n")) };
  } catch {
    return null;
  }
}

/**
 * Async iterator over SSE blocks from a fetch Response body. Splits on
 * the `\n\n` separator and yields complete blocks; tolerant to chunk
 * boundaries landing mid-event.
 */
export async function* sseBlocks(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const decoder = new TextDecoder();
  const reader = body.getReader();
  let buffer = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (value) buffer += decoder.decode(value, { stream: true });
      let idx = buffer.indexOf("\n\n");
      while (idx !== -1) {
        const block = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 2);
        if (block.length) yield block;
        idx = buffer.indexOf("\n\n");
      }
      if (done) {
        if (buffer.length) yield buffer; // trailing block, if any
        return;
      }
    }
  } finally {
    reader.releaseLock();
  }
}
