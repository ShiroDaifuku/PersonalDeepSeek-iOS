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
                                Text("\(item.documents.count) 个文档 · 仅本机").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("启用", isOn: Binding(get: { item.enabled }, set: { setEnabled(item, $0) })).labelsHidden()
                        }
                        HStack {
                            Button { uploadTarget = item; showingImporter = true } label: { Label("添加文件", systemImage: "doc.badge.plus") }
                            Spacer()
                            NavigationLink { LocalKnowledgeDocumentsView(knowledgeBase: item) } label: { Label("文件列表", systemImage: "list.bullet.rectangle") }
                        }
                    }
                    .padding(.vertical, 3)
                    .swipeActions { Button("删除", role: .destructive) { remove(item) } }
                }
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
        context.delete(item); try? context.save()
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
                for url in urls { try await importFile(url, into: target) }
                status = "已在本机索引 \(urls.count) 个文件"
            } catch { status = error.localizedDescription }
            loading = false
        }
    }

    private func importFile(_ url: URL, into knowledgeBase: LocalKnowledgeBase) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 5_000_000 else { throw NSError(domain: "LocalKnowledge", code: 1, userInfo: [NSLocalizedDescriptionKey: "单个文档不能超过 5 MB。"] ) }
        let detected = UTType(filenameExtension: url.pathExtension)
        let mediaType = detected?.preferredMIMEType ?? "text/plain"
        let text: String
        if detected?.conforms(to: .pdf) == true {
            guard let pdf = PDFDocument(data: data) else { throw NSError(domain: "LocalKnowledge", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取 PDF。"] ) }
            text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
        } else {
            guard let decoded = String(data: data, encoding: .utf8) else { throw NSError(domain: "LocalKnowledge", code: 3, userInfo: [NSLocalizedDescriptionKey: "文件不是有效的 UTF-8 文本。"] ) }
            text = decoded
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "LocalKnowledge", code: 4, userInfo: [NSLocalizedDescriptionKey: "文件没有可提取文字；扫描版 PDF 后续可通过 OCR 导入。"] )
        }
        let indexed = await Task.detached(priority: .userInitiated) {
            LocalKnowledgeIndex.chunk(text).enumerated().map { ($0.offset, $0.element, LocalKnowledgeIndex.encode(LocalKnowledgeIndex.embedding(for: $0.element))) }
        }.value
        let document = LocalKnowledgeDocument(name: url.lastPathComponent, mediaType: mediaType, byteCount: data.count, knowledgeBase: knowledgeBase)
        context.insert(document); knowledgeBase.documents.append(document)
        for value in indexed {
            let chunk = LocalKnowledgeChunk(index: value.0, text: value.1, embedding: value.2, document: document)
            context.insert(chunk); document.chunks.append(chunk)
        }
        try context.save()
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
