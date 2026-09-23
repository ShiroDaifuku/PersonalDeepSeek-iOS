# Personal DeepSeek iOS Client — Architecture Contract

## Delivery target

This repository is a runnable first-stage foundation for a personal, sideloaded iOS client. It must not pretend that unimplemented product areas are complete.

The first-stage vertical slice is:

1. Configure either the bundled backend proxy or a personal DeepSeek API key stored in Keychain.
2. Create local conversations and messages with SwiftData.
3. Send stable `system + history + new user message` prefixes.
4. Stream DeepSeek Chat Completions SSE, separating `reasoning_content` and `content`.
5. Ignore blank lines and SSE comments, including `: keep-alive`.
6. Retry pre-stream HTTP 429/5xx failures with bounded exponential backoff and jitter.
7. Parse a natural-language task into a strict application schema, show a confirmation preview, then save it.
8. Provide backend CRUD, pause/resume/delete, due-task execution, execution history, quota, unread-result pause, and monthly budget checks.

## Repository boundaries

- `ios/`: SwiftUI app and pure Swift tests. Deployment target iOS 17. iOS 26-only APIs must be guarded with `@available`.
- `backend/`: Node.js + TypeScript HTTP service. SQLite is acceptable for local development; storage must sit behind repositories so PostgreSQL can replace it later.
- `shared/`: JSON Schema and API examples shared as data contracts.
- `docs/`: setup and manual Xcode verification instructions.

## Non-negotiable design rules

- No API key in source, plist, fixtures, generated project files, or logs.
- The proxy obtains its key only from `DEEPSEEK_API_KEY`.
- BYOK is stored with Keychain Services and sent directly to DeepSeek only when the user explicitly selects direct mode.
- Backend requests send an opaque `user_id`; never send email or device name as `user_id`.
- Every streamed request has an idempotency/request identifier.
- A retry is allowed only before a response stream emits model content. Mid-stream failures remain visible and retry requires a new user action.
- Task schedules store the original timezone and a normalized next-run timestamp.
- Minimum recurring interval is one hour. Server validation is authoritative.
- The task parser output is never persisted until the user confirms it.
- Model-generated tool arguments are decoded into typed values and validated before execution.
- `deepseek-flash` is the budget fallback. Model names remain configurable.

## Deliberately deferred

The following get protocols/placeholders in this stage, not fake implementations: CloudKit production sync, StoreKit subscription, arbitrary document extraction/vector indexing, third-party web search credentials, production APNs, AlarmKit, widgets, Live Activities, Share Extension, deep-research crawling, and content moderation vendors.

## Acceptance checks

- `npm test` and `npm run build` pass in `backend/`.
- Backend starts without a DeepSeek key and exposes a health endpoint; LLM calls fail with a typed configuration error.
- SSE parser tests cover CRLF, fragmented chunks, blank lines, comments, `[DONE]`, reasoning deltas, content deltas, and usage.
- Task validation tests cover timezone, one-off/recurring/monitor kinds, interval lower bound, daily quota, unread auto-pause, and monthly budget fallback/blocking.
- No tracked file contains a token-shaped secret.
- iOS project generation instructions are deterministic and require no paid dependency.
- README clearly separates implemented functionality from deferred functionality.
