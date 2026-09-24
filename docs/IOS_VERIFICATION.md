# iOS manual verification

Run `xcodegen generate` in `ios/`, open `PersonalDeepSeek.xcodeproj`, select an iOS 17+ simulator and run. Verify direct DeepSeek chat, local knowledge retrieval, local research, reasoning disclosure, model switching, conversation relaunch persistence, task confirmation before save, pause/resume, and delete. A physical device requires selecting a personal development team and changing the bundle identifier if it conflicts.

Also verify:

- Save the DeepSeek and Brave Search keys in Keychain; confirm chat and research work while the task service is offline.
- Save the deployed task service's `APP_ACCESS_TOKEN` in Keychain; an incorrect token returns an authentication error and the correct token loads the task list.
- Import a text or text-based PDF into a local knowledge base, then confirm chat and research use relevant excerpts without uploading the full document.
- Ask a normal question and confirm no tool status persists; ask about a private document and confirm local retrieval runs; explicitly request deep research and confirm sourced synthesis runs.
- Ask the assistant to create and then edit a task; confirm neither change reaches the server before the confirmation sheet is accepted.
- Enter `每天上午九点总结我的笔记`; confirm the task tool is forced and a confirmation sheet appears instead of a generic “cannot schedule” response.
- Ask for inline math, a display equation, a Markdown table, and a fenced code block; enable Airplane Mode after the answer is generated and confirm the bundled renderer still displays all four correctly.
- Create, switch, rename, and delete conversations; confirm persistence after relaunch.
- Complete a chat while the app stays foreground and confirm no completed Live Activity remains on the Lock Screen. Background the app during generation and confirm progress appears, then is dismissed immediately if completion happens after returning foreground.
- Stop a streaming response and confirm partial content remains without a spurious error banner.
- Open task history and confirm displayed results are marked read.

On iOS 26+, verify an eligible one-off or fixed-weekly task can request an AlarmKit reminder. On earlier versions, confirm the task remains server-scheduled and the app reports that strong reminders are unavailable. BGContinuedProcessingTask remains deferred; research cancellation and Live Activity progress must continue to behave safely.
