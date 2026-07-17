import AppKit
import SwiftUI

struct BenchmarkShareReviewSheet: View {
    @EnvironmentObject private var loc: Localizer
    @State private var showTechnicalDetails = false
    @State private var showBenchmarkLog = false
    @State private var copiedJSON = false

    let review: BenchmarkShareReview
    let onCancel: () -> Void
    let onSubmit: () -> Void

    init(prepared: BenchmarkSharing.Prepared, onCancel: @escaping () -> Void, onSubmit: @escaping () -> Void) {
        review = BenchmarkShareReview(payload: prepared.payload, keyFingerprint: prepared.keyFingerprint)
        self.onCancel = onCancel
        self.onSubmit = onSubmit
    }

    private let columns = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    privacySummary
                    resultSummary
                    systemSummary
                    artifactSummary
                    identitySummary
                    technicalDetails
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 760, maxWidth: 880,
               minHeight: 620, idealHeight: 720, maxHeight: 860)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(loc.t("Revisa antes de firmar", "Review before signing"))
                    .font(.title3)
                    .bold()
                Text(loc.t("Todavía no se ha subido nada.", "Nothing has been uploaded yet."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(review.payloadByteCount), countStyle: .file))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .help(loc.t("Tamaño exacto del JSON que se firmará", "Exact size of the JSON that will be signed"))
        }
        .padding(20)
    }

    private var privacySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(loc.t("Solo se enviará este benchmark", "Only this benchmark will be sent"),
                  systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(loc.t("ToshLLM no incluye chats, prompts, nombres de cuenta ni rutas locales. Los archivos del modelo tampoco se suben: solo se incluyen su nombre, tamaño y SHA-256.",
                       "ToshLLM does not include chats, prompts, account names, or local paths. Model files are not uploaded either: only their name, size, and SHA-256 are included."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Label(loc.t("Sin contenido de chats", "No chat content"), systemImage: "checkmark.circle")
                Label(loc.t("Sin rutas locales", "No local paths"), systemImage: "checkmark.circle")
                Label(loc.t("Clave privada en Llavero", "Private key stays in Keychain"), systemImage: "checkmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.green.opacity(0.22)) }
    }

    private var resultSummary: some View {
        BenchmarkReviewSection(loc.t("Resultado medido", "Measured result"), systemImage: "gauge.with.dots.needle.67percent") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(review.modelName).font(.title3).bold()
                    Spacer()
                    Text("\(review.quantization) · \(review.family)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    BenchmarkReviewMetric(label: loc.t("Procesamiento del prompt", "Prompt processing"),
                                          value: String(format: "%.1f t/s", review.promptMedian),
                                          detail: runValues(review.promptRuns))
                    BenchmarkReviewMetric(label: loc.t("Generación", "Generation"),
                                          value: String(format: "%.1f t/s", review.generationMedian),
                                          detail: runValues(review.generationRuns))
                }
                Text(loc.t("Mediana de \(review.repetitions) ejecuciones independientes · pp\(review.promptTokens) / tg\(review.generatedTokens)",
                           "Median of \(review.repetitions) independent runs · pp\(review.promptTokens) / tg\(review.generatedTokens)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemSummary: some View {
        BenchmarkReviewSection(loc.t("Equipo y configuración", "Machine and configuration"), systemImage: "desktopcomputer") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                BenchmarkReviewField(label: "GPU", value: review.gpu)
                BenchmarkReviewField(label: "CPU", value: review.cpu)
                BenchmarkReviewField(label: loc.t("Memoria", "Memory"), value: review.memory)
                BenchmarkReviewField(label: loc.t("Sistema", "System"), value: "\(review.machine) · \(review.operatingSystem)")
                BenchmarkReviewField(label: loc.t("Backend / Flash Attention", "Backend / Flash Attention"), value: "\(review.backend) · \(review.flashAttention)")
                BenchmarkReviewField(label: loc.t("Capas GPU / expertos CPU", "GPU layers / CPU experts"), value: "\(review.gpuLayers) / \(review.cpuMoeExperts)")
                BenchmarkReviewField(label: loc.t("Caché KV", "KV cache"), value: review.cacheTypes)
                BenchmarkReviewField(label: loc.t("App / contexto", "App / context"), value: "\(review.appVersion) · \(review.contextDepth)")
            }
        }
    }

    private var artifactSummary: some View {
        BenchmarkReviewSection(loc.t("Modelo identificado", "Model identity"), systemImage: "shippingbox") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(review.artifacts) { artifact in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(artifact.name).font(.callout).bold().lineLimit(1)
                            Spacer()
                            Text(artifact.formattedSize).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(artifact.sha256)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(artifact.sha256)
                    }
                    if artifact.id != review.artifacts.last?.id { Divider() }
                }
            }
        }
    }

    private var identitySummary: some View {
        BenchmarkReviewSection(loc.t("Firma e identidad pública", "Signature and public identity"), systemImage: "signature") {
            VStack(alignment: .leading, spacing: 8) {
                Text(loc.t("La clave privada permanece en el Llavero de este Mac. Esta huella pública permite agrupar tus envíos y verificar que no fueron modificados.",
                           "The private key remains in this Mac's Keychain. This public fingerprint groups your submissions and verifies that they were not modified."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(review.keyFingerprint)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(review.keyFingerprint)
                if !review.contributor.isEmpty {
                    BenchmarkReviewField(label: loc.t("Alias público", "Public alias"), value: review.contributor)
                }
            }
        }
    }

    private var technicalDetails: some View {
        BenchmarkReviewSection(loc.t("Evidencia técnica", "Technical evidence"), systemImage: "curlybraces") {
            DisclosureGroup(isExpanded: $showTechnicalDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(loc.t("El JSON se formatea aquí para facilitar su lectura. Al firmar se usan exactamente los bytes originales; el log completo aparece por separado.",
                               "The JSON is formatted here for readability. Signing uses the exact original bytes; the complete log is shown separately."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(copiedJSON ? loc.t("JSON copiado", "JSON copied") : loc.t("Copiar JSON exacto", "Copy exact JSON"),
                           systemImage: copiedJSON ? "checkmark" : "doc.on.doc",
                           action: copyExactJSON)
                        .buttonStyle(.borderless)
                    ScrollView([.horizontal, .vertical]) {
                        Text(review.formattedJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(minHeight: 180, maxHeight: 280)
                    .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                    DisclosureGroup(isExpanded: $showBenchmarkLog) {
                        ScrollView([.horizontal, .vertical]) {
                            Text(review.rawOutput)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(height: 220)
                        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                    } label: {
                        Text(loc.t("Log completo del benchmark", "Complete benchmark log"))
                    }
                }
                .padding(.top, 10)
            } label: {
                Text(loc.t("Mostrar JSON y log", "Show JSON and log"))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label(loc.t("Solo al confirmar se firmará y enviará este contenido.",
                        "Only after confirmation will this content be signed and sent."),
                  systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(loc.t("Cancelar", "Cancel"), role: .cancel, action: onCancel)
            Button(loc.t("Firmar y enviar benchmark", "Sign and send benchmark"),
                   systemImage: "paperplane.fill", action: onSubmit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func runValues(_ values: [Double]) -> String {
        values.map { String(format: "%.1f", $0) }.joined(separator: " · ")
    }

    private func copyExactJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(review.exactJSON, forType: .string)
        copiedJSON = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedJSON = false
        }
    }
}
