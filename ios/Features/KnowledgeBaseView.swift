import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeBaseView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LocalKnowledgeBase.createdAt) private var knowledgeBases: [LocalKnowledgeBase]
    @State private var query = ""
    @State private var results: [LocalKnowledgeResult] = []
    @State private var selectedKnowledgeBaseID: UUID?
    @State private var uploadTarget: LocalKnowledgeBase?
    @State private var showingImporter = false
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var status: String?
    @State private var loading = false
    @AppStorage("cloudServiceURL") private var cloudServiceURL = CloudServiceDefaults.baseURL
    @AppStorage("opaqueUserID") private var userID = ""

    var body: some View {
        List {
            Section("本地资料库") {
                if knowledgeBases.isEmpty {
                    ContentUnavailableView("还没有资料库", systemImage: "books.vertical", description: Text("资料仅保存在本机，点右上角 + 创建。"))
                }
                ForEach(knowledgeBases) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                Text("\(item.documents.count) 个文档 · \(LocalKnowledgeCloudSync.isEnabled(item.id) ? "已选择云同步" : "仅本机")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("启用", isOn: Binding(get: { item.enabled }, set: { setEnabled(item, $0) })).labelsHidden()
                        }
                        HStack {
                            Button { uploadTarget = item; showingImporter = true } label: { Label("添加文件", systemImage: "doc.badge.plus") }
                            Spacer()
                            NavigationLink { LocalKnowledgeDocumentsView(knowledgeBase: item) } label: { Label("文件列表", systemImage: "list.bullet.rectangle") }
                        }
                        Toggle("允许云端定时任务检索", isOn: Binding(get: { LocalKnowledgeCloudSync.isEnabled(item.id) }, set: { LocalKnowledgeCloudSync.setEnabled($0, for: item.id) }))
                            .font(.caption)
                    }
                    .padding(.vertical, 3)
                    .swipeActions { Button("删除", role: .destructive) { remove(item) } }
                }
            }
            Section("云端知识库") {
                Button(loading ? "正在同步…" : "立即同步所选知识库") { syncToCloud() }.disabled(loading || LocalKnowledgeCloudSync.enabledIDs.isEmpty)
                Text("只有明确开启的知识库会上传文本片段。云端定时任务执行时检索最新一次同步的内容；关闭后再次同步会从云端删除副本。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本地检索") {
                Picker("范围", selection: $selectedKnowledgeBaseID) {
                    Text("全部已启用资料库").tag(Optional<UUID>.none)
                    ForEach(knowledgeBases) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("输入要查找的内容", text: $query, axis: .vertical)
                Button("查询") { runQuery() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(result.documentName).font(.caption).bold()
                            Spacer()
                            Text(result.score, format: .number.precision(.fractionLength(2))).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(result.text).font(.callout).textSelection(.enabled)
                    }.padding(.vertical, 3)
                }
            }
            if let status { Section { Text(status).font(.caption).foregroundStyle(.secondary) } }
        }
        .navigationTitle("资料库")
        .toolbar { Button { showingCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建资料库") }
        .alert("新建资料库", isPresented: $showingCreate) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") { create() }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .plainText, .json, .commaSeparatedText, .xml], allowsMultipleSelection: true) { importFiles($0) }
    }

    private var scopedKnowledgeBases: [LocalKnowledgeBase] {
        guard let selectedKnowledgeBaseID else { return knowledgeBases }
        return knowledgeBases.filter { $0.id == selectedKnowledgeBaseID }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        context.insert(LocalKnowledgeBase(name: name)); try? context.save(); newName = ""; status = "资料库已创建"
    }

    private func setEnabled(_ item: LocalKnowledgeBase, _ enabled: Bool) {
        item.enabled = enabled; try? context.save()
    }

    private func remove(_ item: LocalKnowledgeBase) {
        if selectedKnowledgeBaseID == item.id { selectedKnowledgeBaseID = nil; results = [] }
        LocalKnowledgeCloudSync.setEnabled(false, for: item.id)
        context.delete(item); try? context.save()
    }

    private func syncToCloud() {
        guard let url = URL(string: cloudServiceURL), url.scheme == "https", !userID.isEmpty else { status = "请先在设置中配置云端任务服务"; return }
        loading = true
        Task {
            do { try await KnowledgeSyncAPI(base: url, userID: userID).replaceAll(LocalKnowledgeCloudSync.payloads(from: knowledgeBases)); status = "云端知识库已同步" }
            catch { status = error.localizedDescription }
            loading = false
        }
    }

    private func runQuery() {
        results = LocalKnowledgeIndex.search(query, in: scopedKnowledgeBases)
        status = results.isEmpty ? "没有找到匹配内容" : "找到 \(results.count) 个本地片段"
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard let target = uploadTarget else { return }
        loading = true
        Task {
            do {
                let urls = try result.get()
                for url in urls { try await LocalKnowledgeImporter.importFile(url, into: target, context: context) }
                status = "已在本机索引 \(urls.count) 个文件"
            } catch { status = error.localizedDescription }
            loading = false
        }
    }

}

private struct LocalKnowledgeDocumentsView: View {
    @Environment(\.modelContext) private var context
    @Bindable var knowledgeBase: LocalKnowledgeBase

    var body: some View {
        List {
            ForEach(knowledgeBase.documents.sorted { $0.createdAt > $1.createdAt }) { document in
                VStack(alignment: .leading, spacing: 5) {
                    Text(document.name).font(.headline)
                    Text("\(document.chunks.count) 个片段 · \(ByteCountFormatter.string(fromByteCount: Int64(document.byteCount), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions { Button("删除", role: .destructive) { context.delete(document); try? context.save() } }
            }
            if knowledgeBase.documents.isEmpty { ContentUnavailableView("暂无文件", systemImage: "doc") }
        }
        .navigationTitle(knowledgeBase.name)
    }
}
