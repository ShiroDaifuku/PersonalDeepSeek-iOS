import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct KnowledgeBaseView: View {
    @AppStorage("proxyURL") private var proxyURL = "http://127.0.0.1:8787/"
    @AppStorage("opaqueUserID") private var userID = ""
    @State private var knowledgeBases: [RemoteKnowledgeBase] = []
    @State private var query = ""
    @State private var results: [KnowledgeResult] = []
    @State private var selectedKnowledgeBaseID: String?
    @State private var uploadTarget: RemoteKnowledgeBase?
    @State private var showingImporter = false
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var status: String?
    @State private var loading = false

    var body: some View {
        List {
            Section("知识库") {
                if knowledgeBases.isEmpty && !loading { ContentUnavailableView("还没有知识库", systemImage: "books.vertical", description: Text("点右上角 + 创建一个。")) }
                ForEach(knowledgeBases) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                Text("\(item.documentIds.count) 个文档").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("启用", isOn: Binding(get: { item.enabled ?? true }, set: { setEnabled(item, $0) })).labelsHidden()
                        }
                        HStack {
                            Button { uploadTarget = item; showingImporter = true } label: { Label("上传文件", systemImage: "arrow.up.doc") }
                            Spacer()
                            NavigationLink { KnowledgeDocumentsView(knowledgeBase: item) } label: { Label("文件列表", systemImage: "list.bullet.rectangle") }
                        }
                    }.padding(.vertical, 3)
                }
            }
            Section("查询") {
                Picker("范围", selection: $selectedKnowledgeBaseID) {
                    Text("全部已启用知识库").tag(Optional<String>.none)
                    ForEach(knowledgeBases) { Text($0.name).tag(Optional(itemID($0))) }
                }
                TextField("输入要查找的内容", text: $query, axis: .vertical)
                Button("查询") { runQuery() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(result.documentName).font(.caption).bold(); Spacer(); Text(result.score, format: .number.precision(.fractionLength(2))).font(.caption).foregroundStyle(.secondary) }
                        Text(result.text).font(.callout).textSelection(.enabled)
                    }.padding(.vertical, 3)
                }
            }
            if let status { Section { Text(status).font(.caption).foregroundStyle(.secondary) } }
        }
        .navigationTitle("知识库")
        .toolbar { Button { showingCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建知识库") }
        .refreshable { await refresh() }
        .task { if userID.isEmpty { userID = "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }; await refresh() }
        .alert("新建知识库", isPresented: $showingCreate) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") { create() }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .plainText, .json, .commaSeparatedText, .xml], allowsMultipleSelection: true) { importFiles($0) }
    }

    private func itemID(_ item: RemoteKnowledgeBase) -> String { item.id }
    private var api: KnowledgeAPI? { guard let base = URL(string: proxyURL), !userID.isEmpty else { return nil }; return KnowledgeAPI(base: base, userID: userID) }

    @MainActor private func refresh() async {
        guard let api else { status = "代理 URL 无效"; return }
        loading = true
        do { knowledgeBases = try await api.list(); status = nil } catch { status = error.localizedDescription }
        loading = false
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, !name.isEmpty else { return }
        loading = true
        Task { do { let value = try await api.create(name: name); await MainActor.run { knowledgeBases.append(value); newName = ""; status = "已创建 \(value.name)"; loading = false } } catch { await MainActor.run { status = error.localizedDescription; loading = false } } }
    }

    private func setEnabled(_ item: RemoteKnowledgeBase, _ enabled: Bool) {
        guard let api else { return }
        Task { do { let value = try await api.setEnabled(item, enabled: enabled); await MainActor.run { if let index = knowledgeBases.firstIndex(where: { $0.id == value.id }) { knowledgeBases[index] = value } } } catch { await MainActor.run { status = error.localizedDescription } } }
    }

    private func runQuery() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, !text.isEmpty else { return }
        loading = true
        Task { do { let value = try await api.query(text, knowledgeBaseID: selectedKnowledgeBaseID); await MainActor.run { results = value; status = value.isEmpty ? "没有找到匹配内容" : nil; loading = false } } catch { await MainActor.run { status = error.localizedDescription; loading = false } } }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard let api, let target = uploadTarget else { return }
        Task {
            do {
                let urls = try result.get()
                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    var data = try Data(contentsOf: url, options: .mappedIfSafe)
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    var type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "text/plain"
                    var name = url.lastPathComponent
                    if type == "application/pdf" {
                        guard let pdf = PDFDocument(data: data) else { throw NSError(domain: "KnowledgeUpload", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取 PDF。"] ) }
                        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
                        guard !text.isEmpty, let extracted = text.data(using: .utf8) else { throw NSError(domain: "KnowledgeUpload", code: 3, userInfo: [NSLocalizedDescriptionKey: "该 PDF 没有可提取文字，扫描件暂不支持。"] ) }
                        data = extracted; type = "text/plain"; name += ".txt"
                    }
                    guard data.count <= 5_000_000 else { throw NSError(domain: "KnowledgeUpload", code: 1, userInfo: [NSLocalizedDescriptionKey: "单个文档不能超过 5 MB。"] ) }
                    _ = try await api.upload(to: target, name: name, mediaType: type, data: data)
                }
                await refresh()
                await MainActor.run { status = "已上传 \(urls.count) 个文件" }
            } catch { await MainActor.run { status = error.localizedDescription } }
        }
    }
}

private struct KnowledgeDocumentsView: View {
    let knowledgeBase: RemoteKnowledgeBase
    @AppStorage("proxyURL") private var proxyURL = "http://127.0.0.1:8787/"
    @AppStorage("opaqueUserID") private var userID = ""
    @State private var documents: [RemoteKnowledgeDocument] = []
    @State private var errorText: String?
    @State private var loading = false

    var body: some View {
        List {
            ForEach(documents) { document in
                VStack(alignment: .leading, spacing: 5) {
                    Text(document.name).font(.headline)
                    Text("\(document.mediaType) · \(ByteCountFormatter.string(fromByteCount: Int64(document.size), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions { Button("删除", role: .destructive) { remove(document) } }
            }
            if documents.isEmpty && !loading && errorText == nil { ContentUnavailableView("暂无文件", systemImage: "doc") }
            if let errorText { Text(errorText).foregroundStyle(.red) }
        }
        .navigationTitle(knowledgeBase.name)
        .refreshable { await load() }
        .task { await load() }
    }

    private var api: KnowledgeAPI? {
        guard let base = URL(string: proxyURL), !userID.isEmpty else { return nil }
        return KnowledgeAPI(base: base, userID: userID)
    }

    @MainActor private func load() async {
        guard let api else { errorText = "代理配置无效"; return }
        loading = true
        do { documents = try await api.files(in: knowledgeBase); errorText = nil } catch { errorText = error.localizedDescription }
        loading = false
    }

    private func remove(_ document: RemoteKnowledgeDocument) {
        guard let api else { return }
        Task {
            do { try await api.delete(document: document); await load() }
            catch { await MainActor.run { errorText = error.localizedDescription } }
        }
    }
}
