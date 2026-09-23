import SwiftUI
import SwiftData

@main
struct PersonalDeepSeekApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup { RootView() }
            .modelContainer(for: [Conversation.self, ChatMessage.self, LocalKnowledgeBase.self, LocalKnowledgeDocument.self, LocalKnowledgeChunk.self])
    }
}

struct RootView: View {
    @State private var selectedTab = "chat"
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { ChatView() }.tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }.tag("chat")
            NavigationStack { ResearchView() }.tabItem { Label("研究", systemImage: "magnifyingglass") }.tag("research")
            NavigationStack { TaskListView() }.tabItem { Label("任务", systemImage: "clock") }.tag("tasks")
            NavigationStack { KnowledgeBaseView() }.tabItem { Label("知识库", systemImage: "books.vertical") }.tag("knowledge")
            NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "gear") }.tag("settings")
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepSeekNotificationRoute)) { notification in
            selectedTab = notification.userInfo?["task_id"] == nil && notification.userInfo?["taskId"] == nil ? "chat" : "tasks"
        }
    }
}
