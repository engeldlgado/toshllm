import SwiftUI

// MARK: - Share a benchmark with the community
//
// Opt-in card: no key is created and no request is made until the user picks a
// model, accepts the consent dialog, and reviews the exact JSON. History and any
// remote read happen only on an explicit tap, never on appear.

struct BenchmarkShareCard: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var server: ServerController
    @ObservedObject private var sharing = BenchmarkSharing.shared

    enum Phase: Equatable {
        case idle
        case running          // registering + running the workload (minutes)
        case review           // payload built, waiting for the user to inspect + confirm
        case submitting
        case done(String)     // trust + moderation summary
        case failed(String)
    }

    @State private var selectedModel = ""
    @State private var alias = ""
    @State private var phase: Phase = .idle
    @State private var prepared: BenchmarkSharing.Prepared?
    @State private var showConsent = false
    @State private var showReview = false
    @State private var showIdentity = false
    @State private var showResetConfirm = false
    @State private var history: [BenchmarkSharing.HistoryItem] = []
    @State private var historyLoaded = false
    @State private var historyError: String?

    private var serverBusy: Bool { server.state == .running || server.state == .starting }
    private var working: Bool { phase == .running || phase == .submitting }

    var body: some View {
        Card(title: loc.t("Compartir con la comunidad", "Share with the community"),
             icon: "square.and.arrow.up") {
            VStack(alignment: .leading, spacing: 14) {
                Text(loc.t("Publica el rendimiento de tu equipo en toshllm.com. Nada se envía hasta que eliges un modelo, aceptas y revisas el JSON exacto. No se mandan rutas, nombres de cuenta, ni el contenido de tus chats.",
                           "Publish your machine's performance on toshllm.com. Nothing is sent until you pick a model, accept, and review the exact JSON. No local paths, account names, or chat content are sent."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t("MODELO", "MODEL"))
                            .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                        Picker("", selection: $selectedModel) {
                            Text(loc.t("— elegir —", "— pick —")).tag("")
                            ForEach(models.models) { m in
                                Text(ModelName.forPath(m.url.path).display).tag(m.url.path)
                            }
                        }
                        .labelsHidden().frame(maxWidth: 360, alignment: .leading).disabled(working)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t("ALIAS (OPCIONAL)", "ALIAS (OPTIONAL)"))
                            .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                        TextField(loc.t("Anónimo", "Anonymous"), text: $alias)
                            .textFieldStyle(.roundedBorder).frame(width: 150).disabled(working)
                    }
                    Spacer()
                    shareButton
                }

                statusLine
                Divider().opacity(0.35)
                identitySection
                historySection
            }
        }
        .confirmationDialog(loc.t("¿Compartir este benchmark con la comunidad?",
                                  "Share this benchmark with the community?"),
                            isPresented: $showConsent, titleVisibility: .visible) {
            Button(loc.t("Ejecutar y revisar", "Run and review")) { startPrepare() }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(consentMessage)
        }
        .sheet(isPresented: $showReview) { reviewSheet }
        .alert(loc.t("Restablecer identidad de benchmark", "Reset benchmark identity"),
               isPresented: $showResetConfirm) {
            Button(loc.t("Restablecer", "Reset"), role: .destructive) { sharing.resetIdentity() }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("Se borra la clave de firma de este equipo. Los envíos futuros usarán una identidad nueva, no enlazable a los anteriores. Los benchmarks ya publicados conservan su identidad.",
                       "Deletes this machine's signing key. Future submissions use a new identity, not linkable to previous ones. Already published benchmarks keep their identity."))
        }
    }

    private var consentMessage: String {
        loc.t("ToshLLM enviará: identidad del modelo, descripción del hardware, configuración, las mediciones y las versiones de app/motor. La primera vez que compartes se crea una clave privada en tu Llavero; cada envío queda enlazado a la misma identidad pública para poder agruparlos. Puedes restablecerla cuando quieras.",
              "ToshLLM will send: model identity, hardware description, configuration, the measurements, and app/engine versions. The first time you share, a private key is created in your Keychain; every submission is linked to the same public identity so they can be grouped. You can reset it anytime.")
    }

    @ViewBuilder private var shareButton: some View {
        if working {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phase == .submitting ? loc.t("Enviando…", "Uploading…")
                                          : loc.t("Midiendo…", "Measuring…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Button { showConsent = true } label: {
                Label(loc.t("Compartir", "Share"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedModel.isEmpty || serverBusy)
            .help(serverBusy
                  ? loc.t("Detén el servidor antes de medir: comparten la VRAM.",
                          "Stop the server before benchmarking: they share VRAM.")
                  : loc.t("Ejecuta el workload estándar y te deja revisar el JSON antes de enviarlo.",
                          "Runs the standard workload and lets you review the JSON before sending it."))
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch phase {
        case .done(let summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .running:
            Text(loc.t("Ejecutando el benchmark estándar (pp512/tg128 ×3). Puede tardar varios minutos.",
                       "Running the standard benchmark (pp512/tg128 ×3). May take several minutes."))
                .font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: identity

    @ViewBuilder private var identitySection: some View {
        DisclosureGroup(isExpanded: $showIdentity) {
            VStack(alignment: .leading, spacing: 8) {
                if let fp = sharing.keyFingerprint {
                    HStack(spacing: 8) {
                        Text(fp).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fp, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help(loc.t("Copiar la huella pública", "Copy the public fingerprint"))
                        Spacer()
                        Button(role: .destructive) { showResetConfirm = true } label: {
                            Label(loc.t("Restablecer", "Reset"), systemImage: "pin.slash")
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                    .padding(.top, 4)
                } else {
                    Text(loc.t("Aún no has compartido ningún benchmark. Tu identidad se crea la primera vez que compartes.",
                               "You haven't shared any benchmark yet. Your identity is created the first time you share."))
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
        } label: {
            Text(loc.t("Identidad de benchmark", "Benchmark identity"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: history (load only on tap)

    @ViewBuilder private var historySection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        loadHistory()
                    } label: {
                        Label(loc.t("Actualizar", "Refresh"), systemImage: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.borderless).disabled(!sharing.hasIdentity || sharing.busy)
                    if sharing.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let historyError {
                    Text(historyError).font(.caption).foregroundStyle(.orange)
                } else if !sharing.hasIdentity {
                    Text(loc.t("Comparte un benchmark para ver tu historial.",
                               "Share a benchmark to see your history."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if historyLoaded && history.isEmpty {
                    Text(loc.t("Sin envíos todavía.", "No submissions yet.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(history) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.model).font(.callout.weight(.medium)).lineLimit(1)
                                Text("\(item.gpu) · \(moderationLabel(item))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.1f pp · %.1f tg", item.pp, item.tg))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text(loc.t("Compartidos con la comunidad", "Shared with the community"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func moderationLabel(_ item: BenchmarkSharing.HistoryItem) -> String {
        switch item.moderation {
        case "published", "approved": return loc.t("publicado", "published")
        case "rejected": return loc.t("rechazado", "rejected")
        default: return loc.t("en revisión", "in review")
        }
    }

    // MARK: review sheet

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t("Revisa lo que se enviará", "Review what will be sent"))
                .font(.headline)
            Text(loc.t("Estos son los bytes exactos que se firmarán y subirán. Nada más sale de tu equipo.",
                       "These are the exact bytes that will be signed and uploaded. Nothing else leaves your machine."))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(prepared?.json ?? "")
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 460, minHeight: 300)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
            HStack {
                Spacer()
                Button(loc.t("Cancelar", "Cancel"), role: .cancel) {
                    showReview = false; phase = .idle; prepared = nil
                }
                Button(loc.t("Enviar", "Send")) { submit() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
    }

    // MARK: actions

    private func startPrepare() {
        guard let model = models.models.first(where: { $0.url.path == selectedModel }) else { return }
        phase = .running
        let settings = ServerSettings.fromDefaults()
        let aliasValue = alias.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let p = try await sharing.prepareShare(model: model, settings: settings,
                                                       contributorAlias: aliasValue.isEmpty ? nil : aliasValue)
                prepared = p
                phase = .review
                showReview = true
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func submit() {
        guard let p = prepared else { return }
        showReview = false
        phase = .submitting
        Task {
            do {
                let outcome = try await sharing.submitPrepared(p)
                let trust = outcome.trust == "lab-signed"
                    ? loc.t("verificado (Lab)", "verified (Lab)")
                    : loc.t("registrado por la app", "app-recorded")
                phase = .done(loc.t("Enviado · \(trust) · en revisión",
                                    "Sent · \(trust) · in review"))
                prepared = nil
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func loadHistory() {
        historyError = nil
        Task {
            do {
                history = try await sharing.fetchHistory()
                historyLoaded = true
            } catch {
                historyError = error.localizedDescription
            }
        }
    }
}
