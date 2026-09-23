# iOS manual verification

Run `xcodegen generate` in `ios/`, open `PersonalDeepSeek.xcodeproj`, select an iOS 17+ simulator and run. Verify direct DeepSeek chat, local knowledge retrieval, local research, reasoning disclosure, model switching, conversation relaunch persistence, task confirmation before save, pause/resume, and delete. A physical device requires selecting a personal development team and changing the bundle identifier if it conflicts.

Also verify:

- Save the DeepSeek and Brave Search keys in Keychain; confirm chat and research work while the task service is offline.
- Save the deployed task service's `APP_ACCESS_TOKEN` in Keychain; an incorrect token returns an authentication error and the correct token loads the task list.
- Import a text or text-based PDF into a local knowledge base, then confirm chat and research use relevant excerpts without uploading the full document.
- Create, switch, rename, and delete conversations; confirm persistence after relaunch.
- Stop a streaming response and confirm partial content remains without a spurious error banner.
- Open task history and confirm displayed results are marked read.

On iOS 26+, verify an eligible one-off or fixed-weekly task can request an AlarmKit reminder. On earlier versions, confirm the task remains server-scheduled and the app reports that strong reminders are unavailable. BGContinuedProcessingTask remains deferred; research cancellation and Live Activity progress must continue to behave safely.
