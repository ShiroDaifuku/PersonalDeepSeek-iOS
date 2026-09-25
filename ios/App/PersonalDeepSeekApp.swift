import SwiftUI
import SwiftData

@main
struct PersonalDeepSeekApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer
    private let memoryService: MemoryService

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
            MemoryTurnRecord.self
        ])
        do {
            let container = try ModelContainer(for: schema)
            let store = MemoryStore(modelContainer: container)
            let processor = MemoryProcessor(store: store, extractor: MemoryExtractionClient())
            modelContainer = container
            memoryService = MemoryService(store: store, processor: processor)
        } catch {
            fatalError("Unable to open the application data store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup { RootView(memoryService: memoryService) }
            .modelContainer(modelContainer)
    }
}

struct RootView: View {
    let memoryService: MemoryService
    @State private var selectedTab = "chat"
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { ChatView(memoryService: memoryService) }.tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }.tag("chat")
            NavigationStack { TaskListView() }.tabItem { Label("任务", systemImage: "clock") }.tag("tasks")
            NavigationStack { KnowledgeBaseView() }.tabItem { Label("知识库", systemImage: "books.vertical") }.tag("knowledge")
            NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "gear") }.tag("settings")
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepSeekNotificationRoute)) { notification in
            selectedTab = notification.userInfo?["task_id"] == nil && notification.userInfo?["taskId"] == nil ? "chat" : "tasks"
        }
    }
}
