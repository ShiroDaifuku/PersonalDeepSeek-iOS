#if DEBUG
import SwiftUI

@MainActor
final class MemorySemanticPrecisionViewModel: ObservableObject {
    @Published var running = false
    @Published var status = "Development 80 条 + Held-out 50 条；只在真机运行。"
    @Published var artifacts: MemorySemanticPrecisionArtifacts?

    func run() {
        guard !running else { return }
        running = true; artifacts = nil; status = "正在生成 Contextual embeddings，并仅用 Development Set 冻结参数…"
        Task {
            do {
                let result = try await MemorySemanticPrecisionEvaluator().run()
                artifacts = result
                status = "完成：\(result.report.decision)"
            } catch { status = error.localizedDescription }
            running = false
        }
    }
}

struct MemorySemanticPrecisionView: View {
    @StateObject private var model = MemorySemanticPrecisionViewModel()
    var body: some View {
        Form {
            Section("Step 3.5B") {
                Text("只使用合成数据。Held-out 参数在 Development 调优完成后冻结，并且只评测一次。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.running ? "评测中…" : "运行 Precision Tuning") { model.run() }.disabled(model.running)
                if model.running { ProgressView() }
                Text(model.status).font(.caption)
            }
            if let report = model.artifacts?.report {
                Section("冻结参数") {
                    LabeledContent("Absolute", value: format(report.frozenParameters.minimumAbsoluteSemantic))
                    LabeledContent("Margin", value: format(report.frozenParameters.minimumTopMargin))
                    LabeledContent("Median gap", value: format(report.frozenParameters.minimumMedianGap))
                    LabeledContent("Robust Z", value: format(report.frozenParameters.minimumRobustZ))
                }
                if let metrics = report.heldOut.modes.first(where: { $0.name == "Production hybrid" })?.metrics {
                    Section("Held-out") {
                        LabeledContent("Precision@1", value: format(metrics.precisionAt1))
                        LabeledContent("No-result", value: format(metrics.noResultAccuracy))
                        LabeledContent("False retrieval", value: format(metrics.falseRetrievalRate))
                        LabeledContent("Low-overlap recall", value: format(metrics.lowOverlapRecall))
                    }
                }
            }
            if let artifacts = model.artifacts {
                Section("导出") {
                    ShareLink(item: artifacts.markdownURL) { Label("分享 Markdown", systemImage: "square.and.arrow.up") }
                    ShareLink(item: artifacts.jsonURL) { Label("分享 JSON", systemImage: "square.and.arrow.up") }
                }
            }
        }.navigationTitle("Semantic Precision").navigationBarTitleDisplayMode(.inline)
    }
    private func format(_ value: Double) -> String { String(format: "%.3f", value) }
}
#endif
