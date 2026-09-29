import SwiftUI
import SwiftData

@main
struct PersonalDeepSeekApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer
    private let memoryService: MemoryService
    private let toolExecutionService: ToolExecutionService

    init() {
        let schema = Schema([
            Conversation.self,
            ChatMessage.self,
            LocalKnowledgeBase.self,
            LocalKnowledgeDocument.self,
            LocalKnowledgeChunk.self,
            UserMemoryProfile.self,
            MemoryItem.self,
            MemorySource.self,
            MemoryTurnRecord.self,
            ToolExecutionRecord.self
        ])
        do {
            let container = try ModelContainer(for: schema)
            modelContainer = container
            memoryService = MemoryService(modelContainer: container)
            toolExecutionService = ToolExecutionService(modelContainer: container)
        } catch {
            fatalError("Unable to open the application data store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup { RootView(memoryService: memoryService, toolExecutionService: toolExecutionService) }
            .modelContainer(modelContainer)
    }
}

struct RootView: View {
    let memoryService: MemoryService
    let toolExecutionService: ToolExecutionService
    @State private var selectedTab = "chat"
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { ChatView(memoryService: memoryService, toolExecutionService: toolExecutionService) }.tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }.tag("chat")
            NavigationStack { TaskListView() }.tabItem { Label("任务", systemImage: "clock") }.tag("tasks")
            NavigationStack { KnowledgeBaseView() }.tabItem { Label("知识库", systemImage: "books.vertical") }.tag("knowledge")
            NavigationStack { SettingsView(memoryService: memoryService) }.tabItem { Label("设置", systemImage: "gear") }.tag("settings")
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepSeekNotificationRoute)) { notification in
            selectedTab = notification.userInfo?["task_id"] == nil && notification.userInfo?["taskId"] == nil ? "chat" : "tasks"
        }
        .task(priority: .utility) {
            await memoryService.prepareSemanticProviderIfAvailable()
        }
        .task(priority: .utility) {
            await memoryService.refreshUserProfileIfNeeded()
        }
    }
}
