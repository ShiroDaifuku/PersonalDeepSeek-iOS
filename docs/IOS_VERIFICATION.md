# iOS manual verification

Run `xcodegen generate` in `ios/`, open `PersonalDeepSeek.xcodeproj`, select an iOS 17+ simulator and run. Verify both proxy and direct modes, reasoning disclosure, model switching, conversation relaunch persistence, task confirmation before save, pause/resume, and delete. A physical device requires selecting a personal development team and changing the bundle identifier if it conflicts.

Also verify:

- Save the deployed backend's `APP_ACCESS_TOKEN` in Keychain and use “测试代理连接”.
- An incorrect proxy token returns an authentication error and the correct token loads the task list.
- Create, switch, rename, and delete conversations; confirm persistence after relaunch.
- Stop a streaming response and confirm partial content remains without a spurious error banner.
- Open task history and confirm displayed results are marked read.

iOS 26-only AlarmKit and BGContinuedProcessingTask are intentionally not present in this first stage, so no unguarded newer API can enter the iOS 17 binary.
