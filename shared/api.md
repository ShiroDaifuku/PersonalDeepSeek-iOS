# Local API contract

`GET /health` is public. User routes require `X-User-ID`; when `APP_ACCESS_TOKEN` is configured they also require `Authorization: Bearer <APP_ACCESS_TOKEN>`. The internal scheduler endpoint always uses its separate `INTERNAL_TOKEN`.

- `GET /health`
- `POST /v1/chat/completions` — authenticated local user, SSE passthrough
- `POST /v1/tasks/parse` — return a task draft only
- `POST /v1/tasks` — save a user-confirmed draft
- `GET /v1/tasks`
- `PATCH /v1/tasks/:id`
- `DELETE /v1/tasks/:id`
- `GET /v1/tasks/:id/runs`
- `PATCH /v1/tasks/:id/runs/:runId` — mark a result read with `{ "read": true }`
- `POST /v1/internal/tasks/run-due` — local development scheduler hook, protected by an internal token
- `GET|POST /v1/files`, `DELETE /v1/files/:id` — authenticated image Files API proxy; upload JSON uses `{ name, mediaType, contentBase64, purpose?, expiresAfterSeconds? }`
- `GET|POST /v1/documents`, `GET|DELETE /v1/documents/:id` — local text-document storage
- `GET|POST /v1/knowledge-bases`, `PATCH /v1/knowledge-bases/:id` — create, rename, and enable/disable knowledge bases
- `GET|POST /v1/knowledge-bases/:id/files` — list files or upload/index JSON or multipart (`file`) text documents
- `POST /v1/knowledge/query` — deterministic local retrieval with `{ query, knowledgeBaseId?, limit? }`
- `POST /v1/web/search`, `POST /v1/web/fetch` — configured search provider and SSRF-guarded text fetch
- `POST|DELETE /v1/devices`, `POST|DELETE /v1/live-activities/tokens` — register or unregister APNs device/Live Activity tokens
- `POST /v1/live-activities/:operationId/update` — send a validated ActivityKit update/end payload to the matching registered token

Chat completions automatically retrieve from enabled knowledge bases. When an original system message exists it remains byte-for-byte first; matching chunks are inserted immediately after it as untrusted reference context.

Errors use `{ "error": { "code": string, "message": string, "retryable": boolean } }`.
