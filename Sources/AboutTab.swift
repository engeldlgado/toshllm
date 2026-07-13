import SwiftUI
import Charts

// MARK: - About

enum AppInfo {
    static let version = "0.81.65"
    /// True for the pre-AVX2 legacy build (Info.plist TOSHNoAVX2). Kept on its own
    /// update channel so it never pulls an AVX2 DMG that would SIGILL on those CPUs.
    static let isNoAVX2 = Bundle.main.object(forInfoDictionaryKey: "TOSHNoAVX2") as? Bool ?? false
    static let developerName = "Engelbert Delgado"
    static let developerHandle = "engeldlgado"
    static let githubURL = "https://github.com/engeldlgado"
    static let sponsorURL = "https://www.getly.store/product/toshllm-for-intel-macs-open-source-development-sponsor"
    static let binancePayID = "engeldlgado"
    static let usdtTRC20 = "TFUG271bbbQEmFu4wkFHyvNNkYRZC5JDUf"
    static let donateNoteES = "Si ToshLLM te resulta útil, puedes apoyar el desarrollo con una donación."
    static let donateNoteEN = "If ToshLLM is useful to you, you can support development with a donation."
}

struct AboutView: View {
    @EnvironmentObject var loc: Localizer
    @State private var showDonate = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: icon)
                        .resizable().frame(width: 110, height: 110)
                }
                VStack(spacing: 4) {
                    Text("ToshLLM").font(.largeTitle.weight(.bold))
                    Text(loc.t("Versión", "Version") + " " + AppInfo.version)
                        .foregroundStyle(.secondary)
                }
                Text(loc.t("Modelos de lenguaje locales con aceleración Metal en Macs Intel con GPU AMD.",
                           "Local language models with Metal acceleration on Intel Macs with AMD GPUs."))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)

                Card(title: loc.t("Desarrollador", "Developer"), icon: "person.crop.circle") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppInfo.developerName).font(.headline)
                            Text("@" + AppInfo.developerHandle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSWorkspace.shared.open(URL(string: AppInfo.githubURL)!)
                        } label: {
                            Label("GitHub", systemImage: "link")
                        }
                        Button {
                            showDonate = true
                        } label: {
                            Label(loc.t("Donar", "Donate"), systemImage: "heart.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                        .popover(isPresented: $showDonate, arrowEdge: .bottom) { donatePopover }
                    }
                }
                .frame(maxWidth: 460)

                Card(title: loc.t("Créditos", "Credits"), icon: "hands.clap") {
                    credit("llama.cpp", "ggml-org — " + loc.t("motor de inferencia", "inference engine"))
                    credit("iRon-Llama (Basten7)", loc.t("parches Metal para AMD dGPU en Mac Intel",
                                                         "Metal patches for AMD dGPU on Intel Mac"))
                }
                .frame(maxWidth: 460)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var donatePopover: some View { DonateView() }

    private func credit(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).fontWeight(.medium)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
