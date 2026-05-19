// POST /api/v1/messages
//
// Thin pass-through to https://api.anthropic.com/v1/messages.
// - Anthropic key is injected server-side from ANTHROPIC_API_KEY env var.
// - Request body is forwarded byte-for-byte (Claude API quirks / new fields
//   shouldn't require a code change here).
// - Streaming responses (`stream: true`) are forwarded as-is.
//
// Gated by `requireAuth`: every request must carry a valid Firebase ID Token
// in the Authorization: Bearer <token> header.

import { withCORS, preflight } from "../../lib/cors.js";
import { jsonError } from "../../lib/errors.js";
import { requireAuth } from "../../lib/auth-middleware.js";
import { logError } from "../../lib/telemetry.js";

export const config = { runtime: "edge" };

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";

export default async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return preflight();
  if (req.method !== "POST") {
    return withCORS(jsonError(405, "method_not_allowed", "Use POST."));
  }

  const auth = await requireAuth(req);
  if (!auth.ok) return auth.response;
  // auth.token.uid is available here for logging / per-user metering.

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return withCORS(
      jsonError(500, "config_missing", "ANTHROPIC_API_KEY not set on proxy."),
    );
  }

  // Forward the body raw — no parsing, no re-serialization. Preserves
  // forward-compatibility with any new Anthropic fields.
  const body = await req.arrayBuffer();

  let upstream: Response;
  try {
    upstream = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
      },
      body,
    });
  } catch (e) {
    const msg = (e as Error).message;
    logError({ endpoint: "messages", uid: auth.token.uid, code: "upstream_unreachable", message: msg });
    return withCORS(jsonError(502, "upstream_unreachable", `Failed to reach Anthropic: ${msg}`));
  }

  // Pass status + body through unchanged. Strip hop-by-hop headers; keep
  // content-type so the client knows whether it's JSON or SSE stream.
  const headers = new Headers();
  const contentType = upstream.headers.get("content-type");
  if (contentType) headers.set("content-type", contentType);

  const passthrough = new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers,
  });
  return withCORS(passthrough);
}
