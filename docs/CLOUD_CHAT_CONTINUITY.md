# Cloud Chat Continuity V1 — implementation and deployment gate

## Production deployment update — 2026-10-23 Asia/Hong_Kong

Explicit user approval received for the additive table, dedicated queue and deployment. Worker version `3402aa81-dbeb-43a8-abcd-204701b9cbc5` is deployed at the existing personal Worker URL. `personal-deepseek-chat-runs` was created; only pending migration `0003_chat_jobs.sql` was applied. Existing migrations 0001/0002, task queue, secrets and database were retained. The owner pin was verified against the sole existing task/device owner, not guessed from a request. Its non-secret identifier is configured in wrangler.toml.

Before migration a remote D1 export was downloaded to ignored local `D:/daifuku/builds/cloud-deploy-20261023/pre-chat.sql` (4565 bytes). This backup contains personal data: do not commit or publish it. After deployment: tasks=1, task_runs=1, push_registrations=1, knowledge_bases=0, knowledge_chunks=0. Health and authenticated task-list endpoints returned 200. No existing rows were intentionally edited/deleted. This is not a claim of a byte-for-byte real-user-store restore test.

Re-ran TypeScript check, Vitest 14/14 and actual SQLite tests 6/6 successfully before acceptance. Public live-provider smoke (no personal prompt/photo/phone key): capabilities enabled; missing authentication401, wrong owner403; submitted job `68653a05-8cd8-487a-9f54-a4850459ca05` completed with `CLOUD_OK`. Duplicate identical submission kept the same single row; terminal request_json was erased. Public cancellation job `991488ee-3fb9-4345-b7af-8b210b560748` remained cancelled after seven seconds; different payload with the same ID returned409. These two public test receipts remain under the existing bounded retention policy; production user tasks were not used as fixtures. At most two small public API generations were admitted; tests do not establish exactly-once provider billing.

Still pending: real-device force-quit/reopen, App icon/camera acceptance and companion-mode acceptance after the newly authorized IPA. Pure-text ordinary chat only is durable; tools, attachments, mathematics and companion V1 remain local foreground work. The historical sections below describe the earlier pre-deployment gate and must not be read as the current remote status.

Branch `codex/cloud-chat-continuity`, worktree `D:/daifuku/.worktrees/cloud-chat-continuity`, parent math/icon source `cecefad`. Includes the previously verified chat-quality fixes. No main/canonical merge or IPA is implied.

## Delivered scope

An explicit **off-by-default** Settings switch enables automatic durable routing for eligible **ordinary pure-text, tool-free** chat. Consent explains that the assembled current-conversation context (which may already contain relevant local Memory/Profile context) goes through the configured backend. Request construction stays in the existing assembler. Memory/Profile extraction, ranking, calibration and prompt builders are unchanged. The server never extracts or updates Memory. A recovered complete answer is saved to the original conversation/assistant UUID, then enters the same existing completed-turn eligibility/idempotency pipeline; partial/failed/cancelled output does not. Server completion time is preserved both for reopened jobs and suspended live streams; retrieval time must not refresh an old recent-state fact or supersede newer evidence.

Cloud uses the server's `DEEPSEEK_API_KEY`, not the phone's BYOK. No phone API key is transmitted or persisted in job state. The client retains the backend bearer token in Keychain. The backend requires the existing bearer authentication AND an explicitly configured `CHAT_USER_ID` matching the app's identity. This owner pin is required because the existing shared personal-token service accepts an X-User-ID header; it is not a new multi-account auth system.

Native tools, search, knowledge, attachments, custom models and scheduled-task actions cannot be silently turned into tool-free cloud requests. They automatically retain the original on-device Agent/tool path, with an explicit keep-the-app-running notice when the cloud preference is enabled. No manual mode flip is required for normal tools/images. Pure-text cloud requests that exceed their bounds fail locally rather than silently trimming history or switching keys/transports. Mathematics photo recognition and tutoring still use their independent direct client and are **not** durable cloud jobs in this increment. They must remain foreground work. No autonomous cloud Agent, cloud Memory or APNs completion push is added.

## Data flow

```
local conversation + unchanged Memory/Profile/context assembler
  -> frozen APIClient request + stable assistant UUID
  -> protected local CloudChatOutbox (atomic write before POST)
  -> authenticated POST /v1/chat-jobs
  -> D1 row + compact queue message (owner + job ID, NOT full prompt)
  -> dedicated single-item Queues consumer
  -> one official DeepSeek SSE generation (known 429 backoff only)
  -> coalesced D1 progress, terminal state + erase request_json
  -> foreground polling / app reopen GET by original UUID
  -> update original message -> existing complete-turn gate -> local Memory
```

Cloud execution does not depend on the phone HTTP connection. Before the backend accepts the job there is naturally no guarantee that it has started: force-quitting during local context preparation, before the local frozen outbox write, cannot complete an unsent request. Once the local outbox is written, reopening can safely resubmit a lost acknowledgement using the same ID/hash. An existing queued row can be re-enqueued to repair producer failures; claim CAS prevents another model request. The local process does not create new model requests simply to poll.

No exactly-once billing/completion guarantee is claimed across a worker/provider crash. An ambiguous provider/network failure is recorded as failed/interrupted, not automatically reissued and charged again. Known 429 responses may retry three times. Stale running/queued jobs become explicit failures rather than silently returning an empty response. The device/real Cloudflare close-and-reopen path is still a deployment acceptance gate, not established by mocks.

## Limits and cancellation

- Official HTTPS api.deepseek.com only; redirects not followed with credentials.
- Models flash/pro; thinking and effort preserved. Cloud-only explicit output ceiling 32768 tokens if the input did not set a smaller ceiling.
- 900 KB frozen request; 1 MB bounded submission; 200 messages; output/reasoning combined <=200000 UTF-16 units and <=8 MiB SSE input. No images or native tool transcripts.
- 2 outstanding jobs and 24 submissions per sliding 24h per pinned personal owner, atomically admitted in one SQL statement. This is not a unified monthly cost ledger with scheduled tasks; review cost/budget needs before broader deployment.
- Consumer absolute generation deadline 11 minutes, below the documented Queues 15-minute invocation ceiling. Queue messages older than 15 minutes cannot claim a fresh provider request, even when the phone has not polled. No dependency on post-disconnect waitUntil.
- Stop writes a local durable cancellation tombstone (including Stop-before-insert race) and cancels the remote job. Backend status CAS prevents late completion overwrites; a 5s cancellation poll aborts a silent upstream stream as well. A reopened pending conversation also exposes Cancel.
- Completion deletes server request_json; results kept up to seven days, content/reasoning/usage/input erased by existing cron. Read and admission endpoints reject expired results. A small owner/job/message-ID + request-hash/timing tombstone remains to prevent a lost local receipt from recreating an already charged job after output purge; it contains no prompt or answer. Failed/cancelled paths clear input too. Output is retained until expiry, not sent to third-party analytics/logs.
- Local outbox is protected Application Support files (maximum 20; new admission fails before exceeding the readable limit), removed after successful import or known terminal outcome. No primary SwiftData schema change. Deleted conversations are never recreated by recovery. A pending conversation cannot intentionally start another turn before recovery; other conversations remain independent. Oversized/unsupported input is rejected locally before outbox insertion; a known terminal input/quota rejection does not remain queued forever.
- New cold launch retains the empty composer convention; a banner offers the recovered last answer rather than silently replacing the new chat. Cloud progress polls every two seconds (coarser than direct SSE). Cloud mode does not start a local Live Activity that cannot be updated after termination; existing direct-mode Live Activity behavior is unchanged. No whole-app/latency performance claim is made.

## Deploy ONLY after approval

This source has **not** been deployed. No production SQL, queues, credentials or existing Worker were modified remotely. The wrangler config declares the new binding, but the resource must be provisioned explicitly. Before deploying, preserve/export existing D1 state with the established operational process and review the new additive SQL. Never delete/recreate the old database.

1. Confirm target account, worker and existing D1 database IDs in wrangler.toml; do not use defaults against another account.
2. Create `personal-deepseek-chat-runs` using the account's existing Queues entitlement (`npx wrangler queues create personal-deepseek-chat-runs`). Check quota/pricing; this implementation does not promise zero Cloudflare or DeepSeek cost.
3. Apply only pending additive D1 migrations with `npx wrangler d1 migrations apply personal-deepseek-tasks --remote` after inspecting the pending list. New file is `0003_chat_jobs.sql`. No destructive migration or rewriting previous migrations.
4. Configure `CHAT_USER_ID` in the Worker environment to the exact ID displayed in app Settings -> cloud continuation deployment identity. Keep server `DEEPSEEK_API_KEY` and `APP_ACCESS_TOKEN` as secrets; do not paste them into source or reports. No BYOK upload is required.
5. Deploy this branch's Worker (`npm run deploy` only after explicit deployment authorization). Existing scheduled-task handlers/routes remain separate; smoke-test them after deployment.
6. Authenticated `GET /v1/chat-jobs/capabilities` must return enabled/textOnly/serverKey before enabling the app switch. Missing owner/binding/key fails closed. Health/tasks connection alone does NOT prove cloud chat is deployed.
7. Use a small public test prompt first; verify persisted states, disconnect/reopen, original IDs, lost POST acknowledgement, stop while silent, duplicate delivery and expiry. Verify no duplicate assistant row or Memory extraction record.
8. Only after a separately requested IPA build perform device force-quit acceptance. Keep the setting off in the existing installed app until compatible server/client exist.

## Verification evidence

Local: `npm run check`, `npm test` (14/14 including 7 new cloud contract/consumer cases), `python tests/chat_jobs_sqlite.py` (6/6 actual stdlib SQLite migration/admission/CAS/expiry anti-replay/queue-age tests). Cached existing dependencies referenced via worktree-local node_modules junction, no packages installed. Worker tests inject deterministic provider/D1 fixtures; SQL tests execute SQL extracted from the production source. Neither is a real deployed Cloudflare Queues integration test.

Final production source is `42aec7d778d58db52007a8224b43f36102abeed4`. **Actual macOS/Xcode 16.4 Simulator validation PASS**, [run39585969109](https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/39585969109): 405 ordinary tests (387 passed,18 skipped,zero failures), all five CloudChat cases including time/fingerprint/routing guards passed; generated-old-store migration1/1 PASS (0.595s). Actual logs downloaded to ignored `D:/daifuku/builds/cloud-chat-39585969109/`. This is code/Simulator acceptance, NOT production Cloudflare or device force-quit acceptance. Subsequent commits only archive reports.

Status retrieval briefly failed with repeated TLS EOFs across PowerShell/Python/IPv4 curl/git; it recovered, and final logs were then verified. The temporary network block was not a product test failure and no earlier result was substituted for the final source. No deployment or IPA was triggered while verification was unknown.

Intermediate source `ab726be` / run39583020456 actually succeeded: 405 tests, 18 skipped, zero failures; generated-old-store migration1/1 (0.487s). Its actual logs are in ignored `builds/cloud-chat-39583020456/`. That pass predates server-completion-time preservation, the final direct-route guard and automatic routing hardening, so it is historical evidence only. Earlier run39580387888 and39580924256 were confirmed cancelled. Other superseded runs39582216835,39584902874 and39585127656 were not used as final pass evidence (not all terminal outcomes retrieved). No assertion was relaxed. No private-photo/live provider evaluation enabled.

Final tests additionally assert completed-turn date/fingerprint preservation, cancelled/unpersisted exclusion and automatic local routing for search/knowledge/scheduling/images/custom models. The full existing ordinary/Math/Memory regression suite remained enabled. The next gate is explicit production resource/migration/deployment authorization and real provider/device acceptance, not another implementation step inferred from a transient status-query failure.

Existing warnings observed in final logs: MemorySemanticPrecisionEvaluation.swift343 unused test value; Widget CFBundleVersion1 vs parent17; multiple matching Simulator destinations; third-party Node punycode/url.parse deprecation. No new Swift6 concurrency diagnostic in the changed files was observed. Logs are not warning-free.

Math/icon source cecefad was separately verified: run39577682683, 400 tests (382 passed,18 skipped,0 failures), migration1/1 PASS. Its initial Swift6 PhotosPicker-label failure and fix remain documented on the math branch. The generated icon is an avatar adaptation of the supplied red-haired character; blue-haired in-app video/mascot remains unchanged.

## Remaining acceptance / known limitations

Production migration/deploy, real D1/Queues delivery and provider, device reconnect/force-quit/camera/icon acceptance are not yet performed. No math-job durability or tool-loop durability, no APNs push for ordinary answer completion, no monthly shared spend breaker. Recovery is bounded but not serverless-infinite execution. Query/context data is intentionally sent to your backend only after the explicit switch consent. A job that was never frozen/submitted cannot finish while the phone is off. These are scope boundaries, not hidden completed features.
