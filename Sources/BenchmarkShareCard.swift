import SwiftUI

// MARK: - Share a benchmark with the community
//
// No key or request until the user consents and reviews; history and any remote
// read happen only on an explicit tap, never on appear.

struct BenchmarkShareCard: View {
    let cfg: ServerSettings
    let inheritanceLabel: String

    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var bench: BenchmarkController
    @ObservedObject private var sharing = BenchmarkSharing.shared

    enum Phase: Equatable {
        case idle
        case running          // registering + running the workload (minutes)
        case review           // payload built, waiting for the user to inspect + confirm
        case submitting
        case done(String)     // trust + moderation summary
        case failed(String)
    }

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
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.t("Publica el rendimiento de tu equipo en toshllm.com. Nada se envía hasta que revisas un resumen claro y confirmas. El JSON técnico exacto también está disponible. No se mandan rutas, nombres de cuenta ni contenido de tus chats.",
                       "Publish your machine's performance on toshllm.com. Nothing is sent until you review a clear summary and confirm. The exact technical JSON remains available. No local paths, account names, or chat content are sent."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t("MODELO", "MODEL"))
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                    Text(cfg.modelPath.isEmpty
                         ? loc.t("elige un modelo en Ejecutar benchmark", "pick a model in Run benchmark")
                         : ModelName.forPath(cfg.modelPath).display)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(cfg.modelPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 360, alignment: .leading)
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

            Label(inheritanceLabel, systemImage: "gearshape")
                .font(.caption).foregroundStyle(.secondary)

            statusLine
            Divider().opacity(0.35)
            identitySection
            historySection
        }
        .sheet(isPresented: $showConsent) {
            BenchmarkShareConsentSheet(hasExistingIdentity: sharing.hasIdentity,
                                       onContinue: startPrepare)
        }
        .sheet(isPresented: $showReview) {
            if let prepared {
                BenchmarkShareReviewSheet(prepared: prepared, onCancel: cancelReview, onSubmit: submit)
            }
        }
        .alert(loc.t("Restablecer identidad de benchmark", "Reset benchmark identity"),
               isPresented: $showResetConfirm) {
            Button(loc.t("Restablecer", "Reset"), role: .destructive, action: resetIdentity)
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("Se borra la clave de firma de este equipo. Los envíos futuros usarán una identidad nueva, no enlazable a los anteriores. Los benchmarks ya publicados conservan su identidad.",
                       "Deletes this machine's signing key. Future submissions use a new identity, not linkable to previous ones. Already published benchmarks keep their identity."))
        }
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
            Button(action: beginOrRetryShare) {
                Label(prepared == nil ? loc.t("Compartir", "Share") : loc.t("Reintentar envío", "Retry upload"),
                      systemImage: prepared == nil ? "square.and.arrow.up" : "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(cfg.modelPath.isEmpty || serverBusy)
            .help(serverBusy
                  ? loc.t("Detén el servidor antes de medir: comparten la VRAM.",
                          "Stop the server before benchmarking: they share VRAM.")
                  : loc.t("Ejecuta la medición estándar y muestra un resumen completo antes de enviarlo.",
                          "Runs the standard measurement and shows a complete summary before sending it."))
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
                        } label: {
                            Label(loc.t("Copiar la huella pública", "Copy the public fingerprint"),
                                  systemImage: "doc.on.doc")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help(loc.t("Copiar la huella pública", "Copy the public fingerprint"))
                        Spacer()
                        Button(role: .destructive) { showResetConfirm = true } label: {
                            Label(loc.t("Restablecer", "Reset"), systemImage: "pin.slash")
                        }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(sharing.busy || prepared != nil)
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

    // MARK: actions

    private func cancelReview() {
        showReview = false
        phase = .idle
        prepared = nil
    }

    private func startPrepare() {
        guard let model = models.models.first(where: { $0.url.path == cfg.modelPath }) else { return }
        guard alias.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count <= 80 else {
            phase = .failed(loc.t("El alias no puede superar 80 caracteres.",
                                  "The alias cannot exceed 80 characters."))
            return
        }
        phase = .running
        let aliasValue = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let p = try await sharing.prepareShare(model: model, settings: cfg,
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
                let state = outcome.moderationStatus == "pending"
                    ? loc.t("en revisión", "in review")
                    : loc.t("aprobado", "approved")
                phase = .done(loc.t("Enviado · \(trust) · \(state)",
                                    "Sent · \(trust) · \(state)"))
                bench.recordShared(cfg: cfg, pp: p.pp, tg: p.tg)
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

    private func beginOrRetryShare() {
        if prepared != nil {
            submit()
        } else {
            showConsent = true
        }
    }

    private func resetIdentity() {
        sharing.resetIdentity()
        prepared = nil
        history = []
        historyLoaded = false
        historyError = nil
        phase = .idle
    }
}
