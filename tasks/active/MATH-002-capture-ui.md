# MATH-002 — streamlined photo + worked-solution capture

2026-10-21. User requested a simpler math workflow, automatic reading of existing solution steps, red-haired avatar app icon. After this increment the user additionally authorized implementation of cloud generation continuity, separately staged; no IPA or production deployment authorized here.

- Worktree D:/daifuku/.worktrees/math-capture-ui, branch codex/math-capture-ui.
- Baseline d18a193, the tested client/math/chat-quality stack used for the last device IPA. Preserve all other worktrees, normal Chat/Memory, native Agent/SSE, Research state machine.
- Photo picker (up to six) / camera -> automatic joint transcription -> rendered statement + student work + separate reference solution -> single confirmation and selected teaching mode.
- JSON capture validates lengths and fails closed; no OCR material auto-enters Memory/mastery. Handwritten work and printed/unknown-origin solutions must remain separate. Missing work never invents a student's attempt.
- Confirmed captures and normalized source images use protected, atomic, versioned local per-problem sidecar files; no existing SwiftData schema migration. Supplemental captures append (maximum 20), not replace earlier records. Existing records without sidecars remain readable. Delete removes corresponding sidecars and original image.
- Red-haired avatar derived via built-in image generation from user-provided illustration; square opaque RGB 1024 asset + AppIcon build setting, no change to in-app mascot videos.
- Pending: actual macOS build/XCTest validation; no local Swift/Xcode exists on Windows. Do not claim tests ran before examining remote logs. No live private-photo/model evaluation by default.
- Cloud continuity is a later independent increment: direct mobile SSE is not durable under force-quit; no promise of background completion in this increment. Backend credentials, request ownership, execution lifetime, tool parity, cancellation, final-result import and Memory eligibility require explicit boundaries.
