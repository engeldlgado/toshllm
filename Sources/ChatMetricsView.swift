import SwiftUI

struct ChatMetricsView: View {
    let timings: ChatTimings
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            if timings.cachedTokens != nil {
                metricRow(loc.t("Contexto en caché", "Cached context"),
                          value: tokenValue(timings.cachedTokens), icon: "bolt.horizontal.circle")
            }
            metricRow(loc.t("Procesamiento del prompt", "Prompt processing"),
                      value: combined(tokens: timings.promptTokens,
                                      milliseconds: timings.promptMilliseconds,
                                      rate: timings.promptTokensPerSecond),
                      icon: "book.pages")
            metricRow(loc.t("Generación", "Generation"),
                      value: combined(tokens: timings.generatedTokens,
                                      milliseconds: timings.generationMilliseconds,
                                      rate: timings.generationTokensPerSecond),
                      icon: "sparkles")
        }
        .padding(12)
        .frame(minWidth: 330)
    }

    private func metricRow(_ title: String, value: String, icon: String) -> some View {
        GridRow {
            Label(title, systemImage: icon)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func tokenValue(_ value: Int?) -> String {
        value.map { "\($0.formatted()) tok" } ?? "—"
    }

    private func combined(tokens: Int?, milliseconds: Double?, rate: Double?) -> String {
        let duration = milliseconds.map { Duration.milliseconds($0).formatted(.time(pattern: .minuteSecond)) } ?? "—"
        let speed = rate.map { String(format: "%.2f t/s", $0) } ?? "—"
        return "\(tokenValue(tokens))  ·  \(duration)  ·  \(speed)"
    }
}
