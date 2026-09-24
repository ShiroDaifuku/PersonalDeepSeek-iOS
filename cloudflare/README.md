# Cloudflare task service

This Worker is the authoritative scheduler for PersonalDeepSeek. Chat and
interactive research stay on the iPhone. Knowledge bases remain local by
default; a user may explicitly select individual bases for cloud-task sync.

## Components

- Worker HTTP API: same `/v1/tasks`, run-history, device-token contract as iOS.
- D1: tasks, execution history, idempotent scheduler claims, APNs registrations,
  and explicitly synced knowledge chunks.
- Cron Trigger: scans due tasks every minute.
- Queue: executes DeepSeek calls with retry and a dead-letter queue.
- Worker secrets: app access token, DeepSeek key, optional Brave/APNs credentials.

Web-enabled tasks prefer Brave Search when `BRAVE_SEARCH_API_KEY` is configured
and otherwise fall back to Bing's public RSS search endpoint.

## Deploy

Install dependencies and authenticate with a scoped API token:

```bash
npm install
npx wrangler d1 create personal-deepseek-tasks
npx wrangler queues create personal-deepseek-task-runs
npx wrangler queues create personal-deepseek-task-runs-dlq
```

Put the returned D1 id in `wrangler.toml`, then run:

```bash
npx wrangler d1 migrations apply personal-deepseek-tasks --remote
npx wrangler secret put APP_ACCESS_TOKEN
npx wrangler secret put DEEPSEEK_API_KEY
npx wrangler deploy
```

Optional secrets are `BRAVE_SEARCH_API_KEY`, `APNS_TEAM_ID`, `APNS_KEY_ID`,
`APNS_TOPIC`, and `APNS_PRIVATE_KEY`. The APNs key must be the complete `.p8`
PEM. APNs is automatically reported as `not_configured` until all four APNs
values are present.

The iOS Cloud task service URL is the deployed `workers.dev` URL. Store the same
`APP_ACCESS_TOKEN` in the app's Cloud service token field. `GET /health` is
public; every `/v1/*` route requires both the bearer token and `X-User-ID`.

`PUT /v1/knowledge/sync` replaces the current user's cloud knowledge copy.
Limits are 20 bases, 2,000 chunks, and 8 MB of UTF-8 text. A task stores selected
knowledge-base IDs and retrieves the newest synced chunks at execution time.

## Local checks

```bash
npm test
npm run check
npx wrangler dev
```

Never commit API tokens, `.dev.vars`, or APNs private keys.
