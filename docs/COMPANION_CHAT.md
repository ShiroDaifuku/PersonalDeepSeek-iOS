# Companion chat V1

This branch adds a text-only 大福 experience next to the ordinary assistant. It does not replace the assistant, alter its model preferences, or change the global Memory algorithms.

## UI and lifecycle

- The Chats tab has an Assistant / 大福 segmented picker; `lastChatExperienceMode` persists the last explicitly selected mode. Unknown future values safely fall back to Assistant.
- Both NavigationStacks retain their identities across switches. Switching does not cancel an ordinary assistant/cloud request or move any messages between conversations.
- Notification routing can temporarily reveal Assistant without overwriting the saved mode. Cold launch still uses an unsaved new composer, so merely viewing a mode creates no empty history entry.
- 大福 has its own history sheet, bubbles, composer and existing idle/thinking mascot videos. Reduced Motion/background playback remains governed by the existing video component.
- Ordinary assistant history queries exclude `Conversation.mode == "companion"`; the companion history queries include only that mode.

## Persona and model

`CompanionChatPolicy.persona` adopts the supplied dialogue-style report's personality, short-message style and honesty constraints. It does **not** copy the report's private conversation transcript, account IDs, or fictional QQ/Android/Bilibili tool capabilities.

Only the companion request uses deepseek-flash, thinking disabled, temperature 0.85 and max_tokens 600. The new optional `AgentModelRequest.temperature` defaults to nil, and APIClient emits it only when present; ordinary requests retain their original JSON keys and values.

The companion uses the existing local Keychain API configuration and APIClient. It has **no tools, image uploads, external app control or durable cloud continuation in V1**. The UI explicitly warns that leaving/terminating the app may interrupt its generation. The ordinary assistant's separate cloud continuation remains unchanged. A successful-looking tool claim cannot substitute for a real tool: the persona tells the model these tools are unavailable.

## Context and Memory boundaries

- Each companion Conversation owns its own persona systemPrompt and message history. `mode` uses the existing string field; no schema change or migration is introduced.
- Context includes up to 12 recent messages / 2000 characters from **that Conversation only**, with an orphan leading assistant message removed. Storage retains the entire original history. User input is bounded to 4000 characters.
- The same application MemoryService supplies fail-open relevant memory and ready profile snapshots. ProfileContextBuilder and ChatRequestAssembler retain the existing trusted framing/budgets and authoritative runtime clock.
- Only a nonempty `stop` + `[DONE]` final answer, successfully saved to SwiftData, crosses the existing CompletedTurnEligibility gate. Its full answer, IDs, local-default scope and real completion time are sent to the existing MemoryService.
- No persona text is submitted as user facts. The existing extractor already rejects assistant statements, hypotheticals and role-play as evidence for user facts; that algorithm is unchanged.
- Cancel, disconnection, unexpected tool calls, size violations or `length` termination delete the unfinished assistant placeholder and never trigger Memory extraction. The user's message remains. A killed process may leave an empty placeholder, which is excluded from future model context.
- Responses are displayed in at most three bubbles. Overflow is **merged, never truncated**. No 140-character clipping or artificial typing delay blocks persistence/cancellation/Memory eligibility.
- This is shared relevant Memory, not full cross-conversation history replay, not a guaranteed complete recollection, and not a new memory editing/forgetting UI.

## Validation

`CompanionChatTests` covers mode fallback, persona boundaries, exact non-lossy display segmentation, default ordinary wire equivalence, opt-in sampling validation, bounded independent history, persisted full completed turn through a recording Memory extractor, completion timestamps, cancellation, truncation/disconnection, and refusal to attach an ordinary Conversation.

This work was developed on Windows without Swift/Xcode/XCTest. Local `git diff --check` and source inspection are available; **the tests and iOS UI have not been executed here**. The integrating agent must run actual macOS/Xcode tests before accepting or packaging. On-device acceptance should check the picker/relaunch, independent histories, both animations, short persona replies, cancellation, Assistant tools/cloud continuation and accessibility/dark appearance.
