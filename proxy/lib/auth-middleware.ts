// Shared auth middleware: extracts + verifies the Firebase ID Token from the
// Authorization header. Returns either a 401 Response or the verified token.
//
// Every authenticated endpoint should call this first; if it returns a
// Response, return that to the caller immediately.

import {
  extractBearerToken,
  verifyIdToken,
  FirebaseAuthError,
  type VerifiedIdToken,
} from "./firebase-auth.js";
import { jsonError } from "./errors.js";
import { withCORS } from "./cors.js";

export type AuthResult =
  | { ok: true; token: VerifiedIdToken }
  | { ok: false; response: Response };

export async function requireAuth(req: Request): Promise<AuthResult> {
  const projectId = process.env.FIREBASE_PROJECT_ID;
  if (!projectId) {
    return {
      ok: false,
      response: withCORS(
        jsonError(
          500,
          "config_missing",
          "FIREBASE_PROJECT_ID not set on proxy.",
        ),
      ),
    };
  }

  const raw = extractBearerToken(req);
  if (!raw) {
    return {
      ok: false,
      response: withCORS(
        jsonError(401, "missing_auth", "Authorization: Bearer <token> required."),
      ),
    };
  }

  try {
    const token = await verifyIdToken(raw, projectId);
    return { ok: true, token };
  } catch (e) {
    const err = e as FirebaseAuthError;
    return {
      ok: false,
      response: withCORS(
        jsonError(401, err.code ?? "auth_failed", err.message),
      ),
    };
  }
}
