// Firebase ID Token verification, Edge-compatible.
//
// We don't use firebase-admin because it's Node-only (filesystem, native
// crypto). On Vercel Edge we verify the RS256 JWT ourselves with `jose`:
//
// 1. Pull Google's public x509 certs (rotated periodically; cached in-memory
//    until their max-age expires).
// 2. Decode the JWT header to find `kid`, pick the matching cert.
// 3. jose.jwtVerify with claim checks: iss, aud, exp.
//
// Reference:
// https://firebase.google.com/docs/auth/admin/verify-id-tokens#verify_id_tokens_using_a_third-party_jwt_library

import { importX509, jwtVerify, decodeProtectedHeader } from "jose";

const CERTS_URL =
  "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com";

interface CertCacheEntry {
  certs: Record<string, string>;
  /** Epoch millis when this cache entry should be re-fetched. */
  expiresAt: number;
}

let cache: CertCacheEntry | null = null;

async function getCerts(): Promise<Record<string, string>> {
  const now = Date.now();
  if (cache && cache.expiresAt > now) return cache.certs;

  const res = await fetch(CERTS_URL);
  if (!res.ok) {
    throw new Error(`Failed to fetch Firebase certs: HTTP ${res.status}`);
  }
  const certs = (await res.json()) as Record<string, string>;

  // Honor Cache-Control max-age, fall back to 1 hour.
  const cc = res.headers.get("cache-control") ?? "";
  const m = cc.match(/max-age=(\d+)/);
  const maxAgeSec = m ? parseInt(m[1]!, 10) : 3600;
  cache = { certs, expiresAt: now + maxAgeSec * 1000 };
  return certs;
}

export interface VerifiedIdToken {
  /** Firebase UID. */
  uid: string;
  /** Email if set on the user. */
  email?: string;
  /** Full decoded payload, for advanced callers. */
  payload: Record<string, unknown>;
}

export class FirebaseAuthError extends Error {
  constructor(public code: string, message: string) {
    super(message);
  }
}

/**
 * Verify a Firebase ID Token. Throws FirebaseAuthError on any failure.
 *
 * @param token Raw JWT from the Authorization header (no "Bearer " prefix).
 * @param projectId Firebase project ID (from FIREBASE_PROJECT_ID env var).
 */
export async function verifyIdToken(
  token: string,
  projectId: string,
): Promise<VerifiedIdToken> {
  let kid: string | undefined;
  try {
    const header = decodeProtectedHeader(token);
    kid = header.kid;
  } catch (e) {
    throw new FirebaseAuthError("invalid_token", "Malformed JWT header.");
  }
  if (!kid) {
    throw new FirebaseAuthError("invalid_token", "JWT missing kid header.");
  }

  const certs = await getCerts();
  const pem = certs[kid];
  if (!pem) {
    throw new FirebaseAuthError(
      "unknown_kid",
      `No Firebase cert matches kid=${kid}.`,
    );
  }

  const key = await importX509(pem, "RS256");

  try {
    const { payload } = await jwtVerify(token, key, {
      issuer: `https://securetoken.google.com/${projectId}`,
      audience: projectId,
      algorithms: ["RS256"],
    });

    if (typeof payload.sub !== "string" || payload.sub.length === 0) {
      throw new FirebaseAuthError("invalid_token", "Missing subject (uid).");
    }

    return {
      uid: payload.sub,
      email: typeof payload.email === "string" ? payload.email : undefined,
      payload,
    };
  } catch (e) {
    if (e instanceof FirebaseAuthError) throw e;
    throw new FirebaseAuthError(
      "verification_failed",
      `JWT verification failed: ${(e as Error).message}`,
    );
  }
}

/**
 * Pull the bearer token out of an Authorization header.
 * Returns null if the header is missing or malformed.
 */
export function extractBearerToken(req: Request): string | null {
  const auth = req.headers.get("authorization");
  if (!auth) return null;
  const m = auth.match(/^Bearer\s+(.+)$/i);
  return m ? m[1]!.trim() : null;
}
