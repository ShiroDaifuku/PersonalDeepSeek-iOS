import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation

// Constructed lazily on opening this screen. A math DB failure cannot prevent ordinary chat startup.
struct MathTutorHost: View {
    @State private var model: MathTutorViewModel?
    @State private var loadError: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let model { MathTutorView(model: model) }
                else if let loadError { ContentUnavailableView("数学档案无法打开", systemImage: "exclamationmark.triangle", description: Text(loadError)) }
                else { ProgressView("正在打开数学档案…") }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { model?.stop(); dismiss() } } }
        }
        .interactiveDismissDisabled(model?.busy == true || model?.saving == true || model?.importing == true)
        .task {
            guard model == nil, loadError == nil else { return }
            do {
                let directory = try MathStudyDatabase.localDirectory()
                let container = try MathStudyDatabase.container(at: directory.appendingPathComponent("math.store"))
                let store = MathLearningStore(modelContainer: container)
                try await store.seedTopics()
                let service = MathLearningService(store: store, directory: directory.appendingPathComponent("Photos", isDirectory: true))
                let value = MathTutorViewModel(service: service); model = value; await value.refresh()
            } catch { loadError = "\(error.localizedDescription)\n原数据库不会被删除或重建，普通聊天不受影响。" }
        }
        .onDisappear { model?.stop() }
    }
}

struct MathTutorView: View {
    @ObservedObject var model: MathTutorViewModel
    @State private var selection: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var deleteTarget: MathProblemSnapshot?
    @State private var cameraError: String?
    @FocusState private var focused: Bool
    private var locked: Bool { model.busy || model.saving || model.importing }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("考研数学一 · 本机学习档案", systemImage: "function").font(.headline)
                Text("高等数学 · 线性代数 · 概率论与数理统计\n本阶段记录题目与教学过程，不自动判定薄弱点。图片和题干仅在你发起识别或教学时发送给 DeepSeek。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.current == nil { draft }
                else { savedProblem }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityLabel("错误：\(error)") }
                if !model.status.isEmpty { Text(model.status).font(.caption).foregroundStyle(.secondary) }
                if model.busy {
                    HStack { ProgressView(); Text("正在处理…"); Spacer(); Button("停止", role: .destructive) { model.stop() } }
                }
                if !model.output.isEmpty && (model.current == nil || model.busy || model.error != nil) {
                    RichMessageView(text: model.output)
                    ShareLink("分享当前内容", item: model.output)
                }
            }.padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("数学教学")
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button { showLibrary = true } label: { Image(systemName: "books.vertical") }.accessibilityLabel("数学题目档案").disabled(locked)
                Button { model.newProblem(); selection = nil } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("新题目").disabled(locked)
            }
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            if let cameraError { model.error = cameraError; self.cameraError = nil }
        }) {
            CameraPicker { data in
                guard let data else { return }
                model.acceptPhoto(data)
                if let error = model.error { cameraError = error }
            }
        }
        .onChange(of: selection) { _, value in
            guard let value, !locked else { return }
            model.importing = true
            Task { @MainActor in
                defer { model.importing = false; selection = nil }
                do {
                    guard let data = try await value.loadTransferable(type: Data.self) else { throw MathStudyError.invalidPhoto }
                    model.acceptPhoto(data)
                } catch { model.error = "读取照片失败：\(error.localizedDescription)" }
            }
        }
        .sheet(isPresented: $showLibrary) {
            NavigationStack {
                List {
                    if model.problems.isEmpty { Text("暂无题目，确认题干后会保存在这里。") }
                    ForEach(model.problems) { problem in
                        Button { model.select(problem); showLibrary = false } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(problem.statement).lineLimit(2).foregroundStyle(.primary)
                                Text("\(problem.subject.title) · \(problem.attempts.count) 次教学记录 · 未评估").font(.caption).foregroundStyle(.secondary)
                            }
                        }.swipeActions { Button("删除", role: .destructive) { deleteTarget = problem } }
                    }
                }.navigationTitle("数学题目档案")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showLibrary = false } } }
                    .confirmationDialog("删除这道题、原图及所有教学记录？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
                        Button("删除", role: .destructive) { if let target = deleteTarget { Task { await model.delete(target) } }; deleteTarget = nil }
                    }
            }
        }
    }
    private var draft: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("科目", selection: $model.subject) { ForEach(MathSubject.allCases) { Text($0.title).tag($0) } }
                .onChange(of: model.subject) { _, _ in model.topicID = "" }
            Picker("知识点（可选，手动分类）", selection: $model.topicID) {
                Text("暂不分类").tag("")
                ForEach(MathSyllabus.topics.filter { $0.subject == model.subject }) { Text($0.title).tag($0.id) }
            }
            HStack {
                PhotosPicker(selection: $selection, matching: .images) { Label("选照片", systemImage: "photo") }
                Spacer()
                Button { requestCamera() } label: { Label("拍题", systemImage: "camera") }
            }
            if let photo = model.photo, let image = UIImage(data: photo.data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 230).accessibilityLabel("当前题目原图")
                Button("移除图片", role: .destructive) { model.photo = nil; model.reviewed = false }
                TextField("指定题号或位置（一次一道）", text: $model.target).textFieldStyle(.roundedBorder).focused($focused)
                Button("识别指定题目（不求解）") { focused = false; model.recognize() }.buttonStyle(.bordered)
            }
            Text("题干核对与编辑").font(.headline)
            Text("多题照片请明确题号；模糊符号、图形条件请手动补充。也可以不上传图片，直接输入题目。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.statement).frame(minHeight: 150).padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10)).focused($focused)
                .accessibilityLabel("可编辑题干，支持 LaTeX")
                .onChange(of: model.statement) { _, _ in model.reviewed = false }
            if !model.statement.isEmpty { DisclosureGroup("预览数学公式") { RichMessageView(text: model.statement) } }
            Toggle("我已核对目标题目、符号和全部条件", isOn: $model.reviewed)
            Button { focused = false; Task { await model.confirm() } } label: {
                Text(model.saving ? "保存中…" : "确认题干并保存").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).disabled(!model.reviewed || model.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.disabled(locked)
    }
    @ViewBuilder private var savedProblem: some View {
        if let problem = model.current {
            Text(problem.subject.title).font(.caption).foregroundStyle(.secondary)
            RichMessageView(text: problem.statement)
            if let photo = model.photo, let image = UIImage(data: photo.data) {
                DisclosureGroup("查看原图") { Image(uiImage: image).resizable().scaledToFit() }
            }
            Text("题干有误时请新建更正后的题目；本阶段不覆盖已有作答的题干。") .font(.caption).foregroundStyle(.secondary)
            ForEach(problem.attempts) { attempt in
                VStack(alignment: .leading, spacing: 8) {
                    Text(attempt.mode.title + (attempt.status == .completed ? "" : " · 未完成")).font(.headline)
                    if !attempt.userWork.isEmpty { Text(attempt.userWork).textSelection(.enabled) }
                    if !attempt.response.isEmpty { RichMessageView(text: attempt.response); ShareLink("分享", item: attempt.response) }
                }.padding(.vertical, 8)
                Divider()
            }
            Picker("教学方式", selection: $model.mode) { ForEach(MathTeachingMode.allCases) { Text($0.title).tag($0) } }.disabled(locked)
            Text("你的作答、卡住的位置或具体问题").font(.headline)
            TextEditor(text: $model.work).frame(minHeight: 100).focused($focused)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10)).disabled(locked).accessibilityLabel("我的解题步骤")
            Text("检查步骤时必须提交你的做法；只看答案不会被记为已掌握。AI 解答可能出错，请核验。") .font(.caption).foregroundStyle(.secondary)
            Button("发送教学请求") { focused = false; model.teach() }.buttonStyle(.borderedProminent).disabled(locked)
        }
    }
    private func requestCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { model.error = "当前设备没有可用相机，请选择照片。"; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: showCamera = true
        case .notDetermined:
            Task { if await AVCaptureDevice.requestAccess(for: .video) { showCamera = true } else { model.error = "相机权限未开启，可在系统设置中授权。" } }
        default: model.error = "相机权限未开启，可在系统设置中授权。"
        }
    }
}
