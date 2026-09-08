// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

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
    @State private var showReview = false
    @State private var showIdentity = false
    @State private var showResetConfirm = false
    @State private var history: [BenchmarkSharing.HistoryItem] = []
    @State private var historyLoaded = false
    @State private var historyError: String?

    private var serverBusy: Bool { server.state == .running || server.state == .starting }
    private var working: Bool { phase == .running || phase == .submitting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            intro
            submissionContents
            identityNotice
            shareConfiguration
            statusLine
            HStack(spacing: 18) {
                identitySection
                historySection
            }
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

    private var intro: some View {
        HStack(alignment: .top, spacing: 13) {
            SectionGlyph(systemName: "checkmark.shield")
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("Benchmark verificable", "Verifiable benchmark"))
                    .font(.headline)
                Text(loc.t("Primero se mide en este Mac. Después revisarás exactamente qué se firmará y enviará.",
                           "The measurement runs on this Mac first. You will then review exactly what will be signed and uploaded."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(sharing.hasIdentity
                 ? loc.t("IDENTIDAD EXISTENTE", "EXISTING IDENTITY")
                 : loc.t("NUEVA IDENTIDAD", "NEW IDENTITY"))
                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .foregroundStyle(sharing.hasIdentity ? Color.green : Color.appAccent)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background((sharing.hasIdentity ? Color.green : Color.appAccent).opacity(0.11), in: Capsule())
        }
    }

    private var submissionContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(loc.t("Qué se comparte", "What is shared"), systemImage: "doc.text.magnifyingglass")
                .font(.callout.weight(.semibold))
            HStack(alignment: .top, spacing: 20) {
                BenchmarkConsentInfoRow(
                    title: loc.t("Modelo y medición", "Model and measurement"),
                    detail: loc.t("Nombre, cuantización, hashes, configuración y resultados. Los archivos no se suben.",
                                  "Name, quantization, hashes, configuration, and results. Files are not uploaded."),
                    systemImage: "gauge.with.dots.needle.67percent")
                BenchmarkConsentInfoRow(
                    title: loc.t("Tu contenido queda fuera", "Your content stays private"),
                    detail: loc.t("Sin chats, prompts, cuenta, rutas locales ni contenido de archivos.",
                                  "No chats, prompts, account name, local paths, or file contents."),
                    systemImage: "lock.shield", color: .green)
            }
        }
        .padding(14)
        .cardSurface()
    }

    private var identityNotice: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: AppCodeSignature.hasStableDeveloperIdentity
                  ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(AppCodeSignature.hasStableDeveloperIdentity ? Color.green : Color.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppCodeSignature.hasStableDeveloperIdentity
                     ? loc.t("Instalación firmada y notarizada", "Signed and notarized installation")
                     : loc.t("Compilación local", "Local build"))
                    .font(.callout.weight(.semibold))
                Text(AppCodeSignature.hasStableDeveloperIdentity
                     ? loc.t("La identidad estable permite reutilizar la clave del Llavero sin volver a pedir la contraseña normalmente.",
                             "The stable identity normally reuses the Keychain key without asking for your password again.")
                     : loc.t("Al recompilar con una firma temporal, macOS podría pedir permiso para reutilizar la clave. ToshLLM nunca recibe tu contraseña.",
                             "After rebuilding with a temporary signature, macOS may ask to reuse the key. ToshLLM never receives your password."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background((AppCodeSignature.hasStableDeveloperIdentity ? Color.green : Color.orange).opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            (AppCodeSignature.hasStableDeveloperIdentity ? Color.green : Color.orange).opacity(0.20)))
    }

    private var shareConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel(loc.t("MODELO", "MODEL"))
                    Text(cfg.modelPath.isEmpty
                         ? loc.t("Elige un modelo en la configuración", "Choose a model in the configuration")
                         : ModelName.forPath(cfg.modelPath).display)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(cfg.modelPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel(loc.t("ALIAS PÚBLICO (OPCIONAL)", "PUBLIC ALIAS (OPTIONAL)"))
                    TextField(loc.t("Anónimo", "Anonymous"), text: $alias)
                        .workspaceTextField().frame(width: 180).disabled(working)
                }
                shareButton
            }
            HStack {
                Label(inheritanceLabel, systemImage: "gearshape")
                Spacer()
                Label(loc.t("Nada se envía hasta la confirmación final", "Nothing uploads until final confirmation"),
                      systemImage: "lock")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .cardSurface()
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
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
            .glassButton(prominent: true)
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
                phase = .done(loc.t("Enviado · %@ · %@", "Sent · %@ · %@", "\(trust)", "\(state)"))
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
            startPrepare()
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
