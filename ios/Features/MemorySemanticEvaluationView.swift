#if DEBUG
import SwiftUI

@MainActor
final class MemorySemanticEvaluationViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var status = "尚未运行。必须使用 iOS 17 或更高版本的真实 iPhone。"
    @Published var artifacts: MemorySemanticEvaluationArtifacts?

    func run() {
        guard !isRunning else { return }
        isRunning = true
        artifacts = nil
        status = "正在检测 Apple 模型、请求官方 assets，并运行合成语义基准…"
        Task {
            do {
                let result = try await MemorySemanticPhysicalDeviceEvaluator().run(requestContextualAssets: true)
                artifacts = result
                status = "完成：\(result.report.decision.rawValue)；Final Gate = \(result.report.finalGate)"
            } catch {
                status = error.localizedDescription
            }
            isRunning = false
        }
    }
}

struct MemorySemanticEvaluationView: View {
    @StateObject private var model = MemorySemanticEvaluationViewModel()

    var body: some View {
        Form {
            Section("Step 3.5 真机评测") {
                Text("仅 DEBUG 构建可见。评测只使用内存中的合成 Memory，不读取或写入真实长期记忆。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(model.isRunning ? "正在评测…" : "开始真机语义评测") { model.run() }
                    .disabled(model.isRunning)
                if model.isRunning { ProgressView() }
                Text(model.status).font(.caption)
            }

            if let report = model.artifacts?.report {
                Section("设备") {
                    LabeledContent("型号", value: report.device.model)
                    LabeledContent("iOS", value: report.device.systemVersion)
                    LabeledContent("地区", value: report.device.locale)
                    LabeledContent("真机", value: report.device.physicalDevice ? "是" : "否")
                }
                Section("结果") {
                    LabeledContent("决策", value: report.decision.rawValue)
                    LabeledContent("Final Gate", value: report.finalGate)
                    LabeledContent("Queries", value: String(report.benchmarkQueryCount))
                    ForEach(Array(report.modes.enumerated()), id: \.offset) { _, mode in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(mode.name) · \(mode.provider ?? "fallback")").font(.headline)
                            Text("P@3 \(format(mode.metrics.precisionAt3)) · R@3 \(format(mode.metrics.recallAt3)) · Low-overlap R@3 \(format(mode.metrics.lowOverlapRecallAt3)) · No-result \(format(mode.metrics.noResultAccuracy))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let artifacts = model.artifacts {
                Section("导出") {
                    ShareLink(item: artifacts.markdownURL) { Label("分享 Markdown 报告", systemImage: "square.and.arrow.up") }
                    ShareLink(item: artifacts.jsonURL) { Label("分享 JSON 明细", systemImage: "square.and.arrow.up") }
                    Text("若要验证第二次启动，请先导出本次报告，强制退出并重新打开 App 后再次运行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Memory 语义评测")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func format(_ value: Double) -> String { String(format: "%.3f", value) }
}
#endif
