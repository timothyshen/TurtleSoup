// Uniform JSON error responses.
//
// Keeps every endpoint speaking the same shape:
//   { error: { code: string, message: string } }
// so the Swift client can pattern-match on `error.code` without parsing prose.

export function jsonError(
  status: number,
  code: string,
  message: string,
): Response {
  return Response.json(
    { error: { code, message } },
    { status },
  );
}
