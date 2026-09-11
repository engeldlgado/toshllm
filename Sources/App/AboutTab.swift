// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - About

enum AppInfo {
    static let version = "0.87.2"
    /// True for the pre-AVX2 legacy build (Info.plist TOSHNoAVX2). Kept on its own
    /// update channel so it never pulls an AVX2 DMG that would SIGILL on those CPUs.
    static let isNoAVX2 = Bundle.main.object(forInfoDictionaryKey: "TOSHNoAVX2") as? Bool ?? false
    static let developerName = "Engelbert Delgado"
    static let developerHandle = "engeldlgado"
    static let githubURL = "https://github.com/engeldlgado"
    static let repositoryURL = "https://github.com/engeldlgado/toshllm"
    static let issuesURL = repositoryURL + "/issues"
    static let featureRequestURL = repositoryURL + "/issues/new?template=feature_request.yml"
    static let discussionsURL = repositoryURL + "/discussions"
    static let sponsorURL = "https://www.getly.store/product/toshllm-for-intel-macs-open-source-development-sponsor"
    static let binancePayID = "engeldlgado"
    static let usdtTRC20 = "TFUG271bbbQEmFu4wkFHyvNNkYRZC5JDUf"
    static let donateNoteES = "Si ToshLLM te resulta útil, puedes apoyar el desarrollo con una donación."
    static let donateNoteEN = "If ToshLLM is useful to you, you can support development with a donation."
}

struct AboutView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var updates: UpdateChecker
    @State private var showDonate = false
    @State private var showNotes = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                benefits
                details
                systemInformation
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(WorkspaceStyle.canvas)
    }

    private var hero: some View {
        ZStack(alignment: .leading) {
            WorkspaceHeroArtwork()
            LinearGradient(colors: [WorkspaceStyle.surface.opacity(0.99),
                                    WorkspaceStyle.surface.opacity(0.91),
                                    WorkspaceStyle.surface.opacity(0.12)],
                           startPoint: .leading, endPoint: .trailing)
                .allowsHitTesting(false)
            HStack(spacing: 20) {
                ToshLLMLogo(size: 92)
                VStack(alignment: .leading, spacing: 10) {
                    Text("ToshLLM")
                        .font(.system(size: 32, weight: .bold))
                    HStack(spacing: 9) {
                        Text(loc.t("Versión", "Version") + " " + AppInfo.version)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        updateBadge
                    }
                    Text(loc.t("Modelos de lenguaje locales con aceleración Metal en Macs Intel con GPU AMD.",
                               "Local language models with Metal acceleration on Intel Macs with AMD GPUs."))
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(2)
                    Text(loc.t("Privado. Rápido. Potente. ToshLLM lleva la IA de código abierto a tu equipo con una experiencia nativa y limpia para macOS.",
                               "Private. Fast. Powerful. ToshLLM brings open-source AI to your machine with a clean, native macOS experience."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    HStack(spacing: 9) {
                        updateButton
                        Button {
                            showNotes = true
                        } label: {
                            Label(loc.t("Ver notas de la versión", "View release notes"), systemImage: "doc.text")
                        }
                        .glassButton()
                        .popover(isPresented: $showNotes, arrowEdge: .bottom) { ReleaseNotesPopover() }
                    }
                    if let error = updates.installError {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
                .frame(maxWidth: 650, alignment: .leading)
            }
            .padding(.horizontal, 68)
            .padding(.vertical, 30)
        }
        .frame(minHeight: 250)
        .cardSurface(tint: Color.purple.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: CardMetrics.corner, style: .continuous))
    }

    @ViewBuilder private var updateBadge: some View {
        if let latest = updates.latestVersion {
            Text(loc.t("Disponible %@", "%@ available", latest))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(.orange)
                .background(Color.orange.opacity(0.12), in: Capsule())
        } else {
            Text(loc.t("Más reciente", "Latest"))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(.green)
                .background(Color.green.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder private var updateButton: some View {
        if let latest = updates.latestVersion {
            Button {
                Task { await updates.downloadAndInstall() }
            } label: {
                Label(updates.installing
                      ? loc.t("Actualizando…", "Updating…")
                      : loc.t("Descargar %@", "Download %@", latest),
                      systemImage: updates.installing ? "arrow.down.circle" : "arrow.down.app")
                    .spinningSymbol(updates.installing)
            }
            .glassButton(prominent: true)
            .disabled(updates.installing)
        } else {
            Button {
                Task { await updates.check() }
            } label: {
                Label(updates.checking
                      ? loc.t("Buscando…", "Checking…")
                      : loc.t("Buscar actualizaciones", "Check for updates"),
                      systemImage: "arrow.triangle.2.circlepath")
                    .spinningSymbol(updates.checking)
            }
            .glassButton(prominent: true)
            .disabled(updates.checking)
        }
    }

    private var benefits: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 4), spacing: 0) {
            AboutBenefit(icon: "shield.checkered", color: .pink,
                         title: loc.t("100% local", "100% Local"),
                         detail: loc.t("Tus datos permanecen en tu equipo.", "Your data stays on your machine."))
            AboutBenefit(icon: "bolt.fill", color: .pink,
                         title: loc.t("Aceleración Metal", "Metal Acceleration"),
                         detail: loc.t("Optimizado para Apple Silicon y GPU AMD.", "Optimized for Apple Silicon and AMD GPUs."))
            AboutBenefit(icon: "shippingbox", color: .blue,
                         title: loc.t("Código abierto", "Open Source"),
                         detail: loc.t("Impulsado por la comunidad y modelos abiertos.", "Powered by the community and open models."))
            AboutBenefit(icon: "lock", color: .green,
                         title: loc.t("Privacidad primero", "Privacy First"),
                         detail: loc.t("Sin telemetría ni seguimiento. No necesita la nube.", "No telemetry. No tracking. No cloud required."))
        }
        .padding(.vertical, 8)
        .cardSurface()
    }

    private var details: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                developerCard
                creditsCard
            }
            .frame(maxWidth: .infinity)
            projectLinksCard
                .frame(maxWidth: 470)
        }
    }

    private var developerCard: some View {
        AboutCard(icon: "person.2", title: loc.t("Desarrollador", "Developer")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppInfo.developerName).font(.system(size: 14, weight: .semibold))
                    Text("@" + AppInfo.developerHandle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { open(AppInfo.githubURL) } label: {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .glassButton()
                Button { showDonate = true } label: {
                    Label(loc.t("Donar", "Donate"), systemImage: "heart.fill")
                }
                .glassButton(prominent: true)
                .popover(isPresented: $showDonate, arrowEdge: .bottom) { DonateView() }
            }
        }
    }

    private var creditsCard: some View {
        AboutCard(icon: "hands.clap", title: loc.t("Créditos", "Credits")) {
            VStack(spacing: 0) {
                AboutLinkRow(icon: nil, title: "llama.cpp", detail: "ggml-org · " + loc.t("motor de inferencia", "inference engine")) {
                    open("https://github.com/ggml-org/llama.cpp")
                }
                Divider()
                AboutLinkRow(icon: nil, title: "iRon-Llama (Basten7)",
                             detail: loc.t("Parches Metal para GPU AMD en Mac Intel", "Metal patches for AMD dGPU on Intel Mac")) {
                    open("https://github.com/Basten7/iRon-Llama-RC1")
                }
            }
        }
    }

    private var projectLinksCard: some View {
        AboutCard(icon: "link", title: loc.t("Enlaces del proyecto", "Project links")) {
            VStack(spacing: 0) {
                AboutLinkRow(icon: "chevron.left.forwardslash.chevron.right",
                             title: loc.t("Repositorio de GitHub", "GitHub repository")) { open(AppInfo.repositoryURL) }
                Divider()
                AboutLinkRow(icon: "exclamationmark.triangle",
                             title: loc.t("Reportar un problema", "Report an issue")) { open(AppInfo.issuesURL) }
                Divider()
                AboutLinkRow(icon: "lightbulb",
                             title: loc.t("Solicitar una función", "Request a feature")) { open(AppInfo.featureRequestURL) }
                Divider()
                AboutLinkRow(icon: "bubble.left.and.bubble.right",
                             title: loc.t("Debates", "Discussions")) { open(AppInfo.discussionsURL) }
            }
        }
    }

    private var systemInformation: some View {
        let hardware = AboutHardware.snapshot
        return AboutCard(icon: "desktopcomputer", title: loc.t("Información del sistema", "System information"),
                         subtitle: loc.t("Tu entorno actual.", "Your current environment.")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Button {
                        copySystemInformation(hardware)
                    } label: {
                        Label(copied ? loc.t("Copiado", "Copied") : loc.t("Copiar información", "Copy system info"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .glassButton()
                }
                .padding(.top, -38)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    AboutSystemMetric(icon: "apple.logo", title: "macOS", value: hardware.osVersion)
                    AboutSystemMetric(icon: "cpu", title: loc.t("Chip", "Chip"),
                                      value: hardware.arch == "arm64" ? "Apple Silicon" : "Intel Mac")
                    AboutSystemMetric(icon: "display", title: "GPU", value: hardware.bestGPU?.name ?? "—")
                    AboutSystemMetric(icon: "memorychip", title: loc.t("Memoria", "Memory"),
                                      value: String(format: "%.0f GB", hardware.ramGB))
                }
            }
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copySystemInformation(_ hardware: HardwareInfo) {
        let gpu = hardware.gpus.isEmpty
            ? "—"
            : hardware.gpus.map { "\($0.name) (\($0.vramGB) GB)" }.joined(separator: ", ")
        let value = """
        ToshLLM \(AppInfo.version)\(AppInfo.isNoAVX2 ? " (no-AVX2)" : "")
        \(hardware.osVersion)
        Model: \(hardware.model)
        CPU: \(hardware.cpuBrand) · \(hardware.physicalCores) cores / \(hardware.logicalCores) threads
        Architecture: \(hardware.arch)
        GPU: \(gpu)
        Memory: \(String(format: "%.0f GB", hardware.ramGB))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private enum AboutHardware {
    /// Hardware probing touches sysctl and Metal; keep one result for the whole
    /// process rather than repeating it as the view hierarchy refreshes.
    static let snapshot = HardwareInfo.detect()
}

private struct AboutBenefit: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 48, height: 48)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
    }
}

private struct AboutCard<Content: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    init(icon: String, title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.appAccent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface()
    }
}

private struct AboutLinkRow: View {
    let icon: String?
    let title: String
    var detail: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(WorkspaceStyle.inset,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AboutSystemMetric: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .background(WorkspaceStyle.inset,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(WorkspaceStyle.inset.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(WorkspaceStyle.border))
    }
}
