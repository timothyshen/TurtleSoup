// GET /api/health — sanity check that the proxy is alive.
//
// Used by:
// - CI / deploy smoke tests
// - Manual curl to verify Vercel deployment

export const config = { runtime: "edge" };

export default function handler(_req: Request): Response {
  return Response.json({
    ok: true,
    service: "haiguitang-proxy",
    timestamp: new Date().toISOString(),
  });
}
