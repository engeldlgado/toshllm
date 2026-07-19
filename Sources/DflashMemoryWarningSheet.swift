import SwiftUI

struct DflashMemoryWarningSheet: View {
    let warning: DflashRuntimeWarning
    let useAutomatic: () -> Void
    let disable: () -> Void
    let continueAnyway: () -> Void
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Label(loc.t("DFlash está usando casi toda la VRAM",
                        "DFlash is using almost all VRAM"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.title2)
                .bold()
                .foregroundStyle(.orange)

            Text(loc.t(
                "El servidor mantiene \(usedText) de \(totalText) GiB ocupados (\(fractionText)). Esta configuración puede perder rendimiento, paginar memoria o fallar cuando crezca el contexto.",
                "The server is holding \(usedText) of \(totalText) GiB (\(fractionText)). This configuration can lose performance, page memory, or fail as the context grows."))

            Text(loc.t("Recomendación: vuelve a Auto para que ToshLLM elija una configuración segura; también puedes desactivar DFlash o continuar y recordar esta decisión.",
                       "Recommendation: return to Auto so ToshLLM can choose a safe configuration; you can also disable DFlash or continue and remember this decision."))
                .foregroundStyle(.secondary)

            HStack {
                Button(loc.t("Continuar", "Continue"), action: continueAction)
                Spacer()
                Button(loc.t("Desactivar y reiniciar", "Disable and restart"),
                       role: .destructive, action: disableAction)
                Button(loc.t("Auto y reiniciar", "Auto and restart"),
                       action: automaticAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .interactiveDismissDisabled()
    }

    private var usedText: String {
        warning.usedGB.formatted(.number.precision(.fractionLength(2)))
    }

    private var totalText: String {
        warning.totalGB.formatted(.number.precision(.fractionLength(2)))
    }

    private var fractionText: String {
        warning.fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    private func automaticAction() {
        dismiss()
        useAutomatic()
    }

    private func disableAction() {
        dismiss()
        disable()
    }

    private func continueAction() {
        dismiss()
        continueAnyway()
    }
}
