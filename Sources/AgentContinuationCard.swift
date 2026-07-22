import SwiftUI

struct AgentContinuationCard: View {
    let continueAction: () -> Void
    let stopAction: () -> Void
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(loc.t("El agente alcanzó el límite de 8 turnos. ¿Continuar?",
                        "The agent reached its 8-turn limit. Continue?"),
                  systemImage: "arrow.clockwise.circle")
                .font(.callout)
            HStack {
                Button(loc.t("Continuar", "Continue"), systemImage: "play.fill",
                       action: continueAction)
                    .buttonStyle(.borderedProminent)
                Button(loc.t("Detener", "Stop"), systemImage: "stop.fill",
                       role: .destructive, action: stopAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}
