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
    @AppStorage("lastChatExperienceMode") private var chatExperienceRaw = ChatExperienceMode.assistant.rawValue
    @State private var notificationOpensAssistant = false
    private var chatExperience: ChatExperienceMode { notificationOpensAssistant ? .assistant : .restored(chatExperienceRaw) }
    var body: some View {
        TabView(selection: $selectedTab) {
            chatExperiences.tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }.tag("chat")
            NavigationStack { TaskListView() }.tabItem { Label("任务", systemImage: "clock") }.tag("tasks")
            NavigationStack { KnowledgeBaseView() }.tabItem { Label("知识库", systemImage: "books.vertical") }.tag("knowledge")
            NavigationStack { SettingsView(memoryService: memoryService) }.tabItem { Label("设置", systemImage: "gear") }.tag("settings")
        }
        .onReceive(NotificationCenter.default.publisher(for: .deepSeekNotificationRoute)) { notification in
            selectedTab = notification.userInfo?["task_id"] == nil && notification.userInfo?["taskId"] == nil ? "chat" : "tasks"
            if selectedTab == "chat" { notificationOpensAssistant = true }
        }
        .task(priority: .utility) {
            await memoryService.prepareSemanticProviderIfAvailable()
        }
        .task(priority: .utility) {
            await memoryService.refreshUserProfileIfNeeded()
        }
    }

    private var chatExperiences: some View {
        // Keep both view identities alive when switching; do not cancel or restart
        // an ordinary assistant request merely because its UI becomes invisible.
        ZStack {
            NavigationStack { ChatView(memoryService: memoryService, toolExecutionService: toolExecutionService) }
                .opacity(chatExperience == .assistant ? 1 : 0)
                .allowsHitTesting(chatExperience == .assistant)
                .accessibilityHidden(chatExperience != .assistant)
            NavigationStack { CompanionChatView(memoryService: memoryService, active: chatExperience == .companion && selectedTab == "chat") }
                .opacity(chatExperience == .companion ? 1 : 0)
                .allowsHitTesting(chatExperience == .companion)
                .accessibilityHidden(chatExperience != .companion)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("聊天模式", selection: Binding(get: { chatExperience }, set: {
                notificationOpensAssistant = false
                chatExperienceRaw = $0.rawValue
            })) {
                ForEach(ChatExperienceMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 7).background(.bar)
        }
    }
}
