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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { model?.stop(); dismiss() }.disabled(model?.saving == true || model?.importing == true) } }
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
    @State private var selection: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var deleteTarget: MathProblemSnapshot?
    @State private var cameraError: String?
    @State private var cameraImported = false
    @FocusState private var focused: Bool
    private var locked: Bool { model.busy || model.saving || model.importing }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("考研数学一 · 本机学习档案", systemImage: "function").font(.headline)
                Text("拍题及已有解题过程 → 核对公式 → 开始辅导。不用手抄步骤；本阶段不自动判定薄弱点。图片会发送给 DeepSeek 识别。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.current == nil { draft }
                else { savedProblem }
                if model.pendingCapture != nil { captureReview }
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
                Button { model.newProblem(); selection = [] } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("新题目").disabled(locked)
            }
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            if let cameraError { model.error = cameraError; self.cameraError = nil }
            else if cameraImported { cameraImported = false; model.recognize() }
        }) {
            CameraPicker { data in
                guard let data else { return }
                model.acceptPhoto(data)
                cameraImported = model.error == nil
                if let error = model.error { cameraError = error }
            }
        }
        .onChange(of: selection) { _, value in
            guard !value.isEmpty, !locked else { return }
            model.importing = true
            Task { @MainActor in
                do {
                    var images: [PendingAttachment] = []
                    for item in value {
                        guard let data = try await item.loadTransferable(type: Data.self), let image = PendingAttachment.image(data: data) else { throw MathStudyError.invalidPhoto }
                        images.append(image)
                    }
                    model.acceptPhotos(images)
                    model.importing = false; selection = []
                    model.recognize()
                } catch { model.importing = false; selection = []; model.error = "读取照片失败：\(error.localizedDescription)" }
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
            photoActions
            if let photo = model.photo, let image = UIImage(data: photo.data) {
                DisclosureGroup("已上传 \(model.capturePhotos.count) 张图片 · 查看原图") {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 230)
                }
                if model.pendingCapture == nil {
                    Button("重新识别") { focused = false; model.recognize() }.buttonStyle(.bordered)
                }
            }
            DisclosureGroup("指定题号或分类（可选）") {
                TextField("多题时指定题号", text: $model.target).textFieldStyle(.roundedBorder)
                classification
            }
            if model.pendingCapture == nil {
                DisclosureGroup("直接输入题目") {
                    TextEditor(text: $model.statement).frame(minHeight: 130).focused($focused).accessibilityLabel("题干")
                    if !model.statement.isEmpty { RichMessageView(text: model.statement) }
                    Button("确认题干并保存") {
                        focused = false; model.reviewed = true
                        Task { await model.confirm() }
                    }.disabled(model.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.disabled(locked)
    }
    private var photoActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PhotosPicker(selection: $selection, maxSelectionCount: 6, matching: .images) {
                    Label(model.current == nil ? "上传题目与解题过程" : "上传新的解题过程", systemImage: "photo.on.rectangle")
                }.buttonStyle(.borderedProminent)
                Button { requestCamera() } label: { Image(systemName: "camera") }.buttonStyle(.bordered).accessibilityLabel("拍照识别")
            }
            Text("最多 6 张。同一题的题干、手写步骤和参考解答可一并选择；选完自动识别。多题请先在可选设置中指定题号。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(locked)
    }
    private var classification: some View {
        VStack {
            Picker("科目", selection: $model.subject) { ForEach(MathSubject.allCases) { Text($0.title).tag($0) } }
                .onChange(of: model.subject) { _, _ in model.topicID = "" }
            Picker("知识点", selection: $model.topicID) {
                Text("暂不分类").tag("")
                ForEach(MathSyllabus.topics.filter { $0.subject == model.subject }) { Text($0.title).tag($0.id) }
            }
        }
    }
    private var captureReview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("核对识别结果").font(.title2.bold())
            RichMessageView(text: model.statement)
            if !model.work.isEmpty {
                Label("照片中的我的解题过程", systemImage: "pencil.line").font(.headline)
                RichMessageView(text: model.work)
            } else { Text("未识别到你的手写步骤；无需手动补写，可继续上传照片。").font(.caption).foregroundStyle(.secondary) }
            if let capture = model.pendingCapture {
                if !capture.referenceSolution.isEmpty {
                    DisclosureGroup("参考解答（不计作你的作答）") { RichMessageView(text: capture.referenceSolution) }
                }
                ForEach(Array(capture.uncertainties.enumerated()), id: \.offset) { _, text in
                    Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            DisclosureGroup("识别有误？少量修正", isExpanded: $model.editingCapture) {
                if model.current == nil { TextEditor(text: $model.statement).frame(minHeight: 100).accessibilityLabel("修正题干") }
                Text("修正我的步骤（可留空）").font(.caption)
                TextEditor(text: $model.work).frame(minHeight: 100).accessibilityLabel("修正识别的解题过程")
                if model.pendingCapture != nil {
                    Text("参考解答（来源不确定时保留在此，不计作用户步骤）").font(.caption)
                    TextEditor(text: Binding(get: { model.pendingCapture?.referenceSolution ?? "" }, set: { model.pendingCapture?.referenceSolution = $0 })).frame(minHeight: 100)
                }
            }
            Picker("辅导方式", selection: $model.mode) { ForEach(MathTeachingMode.allCases) { Text($0.title).tag($0) } }
            Button("确认无误，开始辅导") {
                focused = false
                Task { await model.confirmCapture(); if model.pendingCapture == nil && model.error == nil { model.teach() } }
            }.buttonStyle(.borderedProminent)
                .disabled(locked || model.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding().background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .disabled(locked)
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
                    if !attempt.userWork.isEmpty { RichMessageView(text: attempt.userWork) }
                    if !attempt.response.isEmpty { RichMessageView(text: attempt.response); ShareLink("分享", item: attempt.response) }
                }.padding(.vertical, 8)
                Divider()
            }
            if model.pendingCapture == nil {
                photoActions
                if let capture = model.capture {
                    DisclosureGroup("已识别的解题过程与参考解答") {
                        if !capture.studentWork.isEmpty { Text("我的步骤").font(.headline); RichMessageView(text: capture.studentWork) }
                        if !capture.referenceSolution.isEmpty { Text("参考解答").font(.headline); RichMessageView(text: capture.referenceSolution) }
                    }
                }
                Picker("辅导方式", selection: $model.mode) { ForEach(MathTeachingMode.allCases) { Text($0.title).tag($0) } }.disabled(locked)
                DisclosureGroup("补充问题或修正步骤（可选）") {
                    TextEditor(text: $model.work).frame(minHeight: 100).focused($focused).accessibilityLabel("可选补充问题")
                }.disabled(locked)
                Text("检查步骤使用照片识别的你的做法；参考答案不会记为已掌握。AI 解答可能出错，请核验。") .font(.caption).foregroundStyle(.secondary)
                Button("继续辅导") { focused = false; model.teach() }.buttonStyle(.borderedProminent).disabled(locked)
            }
        }
    }
    private func requestCamera() {
        cameraImported = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { model.error = "当前设备没有可用相机，请选择照片。"; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: showCamera = true
        case .notDetermined:
            Task { if await AVCaptureDevice.requestAccess(for: .video) { showCamera = true } else { model.error = "相机权限未开启，可在系统设置中授权。" } }
        default: model.error = "相机权限未开启，可在系统设置中授权。"
        }
    }
}
