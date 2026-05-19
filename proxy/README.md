# haiguitang-proxy

Edge proxy for the haiguitang macOS app. Hosted on Vercel.

## Responsibilities

1. **Claude API forwarder** — clients hit this instead of `api.anthropic.com` directly so the Anthropic key stays server-side.
2. **Firebase ID Token gate** — every request must carry a valid `Authorization: Bearer <firebase-id-token>` header.
3. **AI puzzle generation** — `/api/v1/generate-puzzle` calls Claude with tool_use to return structured `{title, scenario, answer, hint, difficulty}`.
4. **AI post-game review** — `/api/v1/generate-review` produces structured `{summary, key_moments[], tip}` from a finished game's transcript.

## Endpoints

| Path | Method | Auth | Notes |
|---|---|---|---|
| `/api/health` | GET | none | Liveness check. |
| `/api/v1/messages` | POST | Firebase ID Token | Forwards body 1:1 to `https://api.anthropic.com/v1/messages`. Streaming pass-through when client sets `stream: true`. |
| `/api/v1/generate-puzzle` | POST | Firebase ID Token | `{ idea, difficulty?, stream? }` → `{ puzzle: {...} }` (non-stream) or progress+complete SSE (stream). |
| `/api/v1/generate-review` | POST | Firebase ID Token | `{ puzzle, transcript, isWon, questionCount, stream? }` → `{ review: {...} }` (non-stream) or progress+complete SSE (stream). |

## Local dev

```bash
cd proxy
npm install
vercel dev
# health check
curl http://localhost:3000/api/health
```

## Deploy

```bash
vercel --prod
```

## Required env vars (set in Vercel dashboard)

| Name | Where used | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | all `/v1/*` endpoints | Server-side Anthropic key. **Never ship to client.** |
| `FIREBASE_PROJECT_ID` | ID Token verification | From Firebase console. Used by `lib/firebase-auth.ts` to validate the `iss` / `aud` claims. |
