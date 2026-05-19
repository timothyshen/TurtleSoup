// Structured logging helper for proxy endpoints.
//
// Vercel Edge captures all console output and exposes it via the project
// dashboard. JSON-shaped log lines are queryable; free-form strings are
// not. Every catch block in the API routes should call `logError` so
// failure rates and patterns can be derived without a paid observability
// stack.
//
// Not telemetry-as-product (no metrics endpoint, no aggregation here) —
// just consistent error shapes for Vercel logs.

interface LogContext {
  /** Endpoint name, e.g. "generate-puzzle". */
  endpoint: string;
  /** Firebase UID if the request was authenticated. */
  uid?: string;
  /** Short machine code for the failure kind. */
  code: string;
  /** Free-form details — error message, body excerpt, etc. */
  message?: string;
  /** Anything else useful for triage. Kept narrow so logs stay scannable. */
  extra?: Record<string, unknown>;
}

/**
 * Log a handled error. Mirrors the shape returned to the client so log
 * lines and HTTP responses can be correlated by `code`.
 */
export function logError(ctx: LogContext): void {
  // Use console.error so Vercel surfaces it under the error severity
  // filter; console.log is harder to triage from a noisy info stream.
  console.error(JSON.stringify({
    level: "error",
    endpoint: ctx.endpoint,
    code: ctx.code,
    ...(ctx.uid     ? { uid: ctx.uid }         : {}),
    ...(ctx.message ? { message: ctx.message } : {}),
    ...(ctx.extra   ? { extra: ctx.extra }     : {}),
    timestamp: new Date().toISOString(),
  }));
}
