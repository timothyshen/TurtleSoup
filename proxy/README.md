# haiguitang-proxy

Edge proxy for the haiguitang macOS app. Hosted on Vercel.

## Responsibilities

1. **Claude API forwarder** — clients hit this instead of `api.anthropic.com` directly so the Anthropic key stays server-side.
2. **Firebase ID Token gate** — every request must carry a valid `Authorization: Bearer <firebase-id-token>` header.
3. (Later) **WeChat → Firebase Custom Token bridge** — exchanges a `code` from WeChat OAuth for a Firebase custom token so wx login plugs into the existing Firebase Auth user model.
4. (Later) **AI puzzle generation** — `/api/v1/generate-puzzle` calls Claude with tool_use to return structured `{title, scenario, answer, hint, difficulty}`.

## Endpoints

| Path | Method | Auth | Notes |
|---|---|---|---|
| `/api/health` | GET | none | Liveness check. |
| `/api/v1/messages` | POST | Firebase ID Token | Forwards body 1:1 to `https://api.anthropic.com/v1/messages`. |
| `/api/auth/wechat/exchange` | POST | none | (planned) `{ code }` → `{ customToken }`. |
| `/api/v1/generate-puzzle` | POST | Firebase ID Token | (planned) `{ idea, difficulty? }` → `{ title, scenario, answer, hint, difficulty }`. |

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
| `ANTHROPIC_API_KEY` | `/v1/messages` | Server-side Anthropic key. **Never ship to client.** |
| `FIREBASE_PROJECT_ID` | ID Token verification | From Firebase console. |
| `FIREBASE_CLIENT_EMAIL` | (wx bridge) | From service account JSON. |
| `FIREBASE_PRIVATE_KEY` | (wx bridge) | From service account JSON. Use `\n` for newlines. |
| `WECHAT_APP_ID` | (wx bridge) | From wx open platform. |
| `WECHAT_APP_SECRET` | (wx bridge) | From wx open platform. |
