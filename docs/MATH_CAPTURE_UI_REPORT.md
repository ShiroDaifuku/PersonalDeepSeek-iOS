# Math capture and app icon — 2026-10-21

Source: `cecefad1ab010d849b6aa33e25e85633f2ed8695`, branch `codex/math-capture-ui`, based on tested chat-quality source `d18a193` (not historical search-fallback).

## User flow

Upload up to six pictures of the same exercise, including existing handwritten work / printed solution, or use the camera. Selection starts one recognition call automatically. The default screen renders the statement and student work with the existing local Markdown/LaTeX renderer. Reference/unknown-origin solutions are clearly separate. A single explicit confirmation saves the reviewed material and starts the chosen tutoring mode. Classification, manual entry and small transcription corrections are optional disclosures, not mandatory steps. New photos of a saved exercise can supplement its work without changing the confirmed statement. Raw OCR JSON is never displayed as the tutoring answer.

Structured capture contains `statement`, `studentWork`, `referenceSolution`, `uncertainties`. Missing/unreadable work is not invented. Invalid JSON, truncated and cancelled output cannot create a confirmed problem. The current image-reading call is prompt-constrained JSON with local validation, not a provider-enforced strict schema. Arbitrary OCR/handwriting accuracy is not established by deterministic tests.

## Storage and boundaries

`MathCapture`/record/archive DTOs live in Core/MathCapture.swift. Confirmed records, normalized source images and timestamps append to `<problem UUID>.capture.json` under the existing protected local MathStudy Photos directory. Version 1, maximum six images per record, twenty records per problem; explicit length/size checks. Atomic protected file writes; creation cleans up sidecars/photos if problem storage fails. Existing Math SwiftData entities and the primary chat/Memory schema are unchanged. Existing problem files without capture sidecars remain supported. Supplemental records do not overwrite previous provenance; deletion targets only the chosen problem's sidecar/photo. This initial sidecar embeds images and rewrites its bounded archive, not a large-scale image database.

Only confirmed capture context can enter this problem's tutoring request. Reference solutions are untrusted source data, not student performance. No automatic weakness/mastery algorithm, extraction, cross-question recall, general Memory writes or new background AI calls were added. ChatView, AgentRunner, APIClient, SSE, MessagePrefix and Memory/Profile implementation are unchanged. Math streaming reuses the incremental exact counter rather than repeatedly counting its full output.

## Icon

`ios/App/Resources/Assets.xcassets/AppIcon.appiconset/RedMaid-1024.png`, 1024×1024 opaque RGB, configured by `ASSETCATALOG_COMPILER_APPICON_NAME` in XcodeGen. Uses built-in image generation/editing from the supplied illustration, then deterministic resizing for asset compliance. This is an avatar adaptation, not a pixel-identical crop. Original user image is untouched; in-app blue-haired mascot/video assets are unchanged. Subsequent builds from this branch/descendants use this icon; other branches and existing installations are not silently changed.

Prompt: “Extract only the red-haired character's head and upper shoulders as a close-up square iOS avatar; preserve red hair, pink eyes, maid headdress, pointed ears and expression; remove the separate purple-haired chibi and speech bubble; clean opaque white background; no text, border, rounded corners or mockup.”

## Validation

Windows has no Swift/Xcode. Actual test-only macOS/Xcode workflow was dispatched, no IPA workflow. First source `2eebe91` / run `39577338445` failed Swift 6 compile isolation in the PhotosPicker Sendable label. The production fix snapshots the title before entering that label; no concurrency assertions were removed. Final run `39577682683` is checked separately; final counts must come from its logs, not estimated counts. New deterministic cases cover parse/failure, student/reference separation, archived images/reload/append/delete, confirmation gating, supplemental capture and cancellation. Existing Math and ordinary Chat/Memory/Markdown tests remain enabled.

Final validation source `cecefad` / [run 39577682683](https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/39577682683): **SUCCESS**. Actual Xcode 16.4 build, 400 ordinary tests (382 passed, 18 opt-in skipped, zero failures), generated-old-store migration 1/1 PASS (0.680s). Logs saved under ignored `D:/daifuku/builds/math-capture-39577682683/`. No live private photo/API evaluation or IPA was run. Earlier compile failure is retained, not overwritten by the successful rerun.

## Generation continuity

Current direct mobile requests cannot guarantee completion after force-quit. No background trick, timer, Live Activity or local notification makes that durable. User first selected separate cloud work and then authorized doing it after this increment. Cloud continuation is a separate stage with persistent server jobs and explicit credential/privacy/tool boundaries, not an already delivered capability of this source.

No IPA, main/canonical merge, production deployment/migration, private-photo API smoke or live handwriting benchmark performed by this increment. Device workflow, camera/photo-picker interaction, icon installation and real handwriting accuracy still require a future explicitly authorized device build/test.
