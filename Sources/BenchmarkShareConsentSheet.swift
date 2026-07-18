import SwiftUI

struct BenchmarkShareConsentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: Localizer

    let hasExistingIdentity: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        LinearGradient(colors: [.accentColor, .purple],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 13)
                    )
                    .shadow(color: Color.accentColor.opacity(0.24), radius: 14, y: 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(loc.t("Comparte un benchmark verificable",
                               "Share a verifiable benchmark"))
                        .font(.title2)
                        .bold()
                    Text(loc.t("Primero se mide en este Mac. Después podrás revisar exactamente qué se firmará y enviará.",
                               "The measurement runs on this Mac first. You will then review exactly what will be signed and uploaded."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(hasExistingIdentity
                     ? loc.t("IDENTIDAD EXISTENTE", "EXISTING IDENTITY")
                     : loc.t("NUEVA IDENTIDAD", "NEW IDENTITY"))
                    .font(.caption)
                    .bold()
                    .foregroundStyle(hasExistingIdentity ? Color.green : Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background((hasExistingIdentity ? Color.green : Color.accentColor).opacity(0.1), in: Capsule())
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 15) {
                            BenchmarkConsentInfoRow(
                                title: loc.t("Modelo y archivos identificados", "Model and identified files"),
                                detail: loc.t("Nombre, cuantización, tamaño y hashes SHA-256. Los archivos del modelo no se suben.",
                                              "Name, quantization, size, and SHA-256 hashes. Model files are not uploaded."),
                                systemImage: "shippingbox"
                            )
                            Divider()
                            BenchmarkConsentInfoRow(
                                title: loc.t("Equipo, configuración y rendimiento", "Hardware, configuration, and performance"),
                                detail: loc.t("GPU, CPU, memoria, macOS, parámetros del benchmark y los resultados de tres ejecuciones.",
                                              "GPU, CPU, memory, macOS, benchmark parameters, and the results of three runs."),
                                systemImage: "gauge.with.dots.needle.67percent"
                            )
                            Divider()
                            BenchmarkConsentInfoRow(
                                title: loc.t("Tu contenido privado queda fuera", "Your private content stays private"),
                                detail: loc.t("No se incluyen chats, prompts, nombres de cuenta, rutas locales ni el contenido de tus archivos.",
                                              "Chats, prompts, account names, local paths, and file contents are not included."),
                                systemImage: "lock.shield",
                                color: .green
                            )
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label(loc.t("Qué contiene el envío", "What the submission contains"),
                              systemImage: "doc.text.magnifyingglass")
                            .font(.headline)
                    }

                    GroupBox {
                        BenchmarkConsentInfoRow(
                            title: hasExistingIdentity
                                ? loc.t("Se usará tu clave existente", "Your existing key will be used")
                                : loc.t("Se creará una clave privada", "A private key will be created"),
                            detail: loc.t("La clave permanece en el Llavero de este Mac. Solo la huella pública acompaña al benchmark para demostrar que no fue alterado y agrupar tus envíos.",
                                          "The key stays in this Mac's Keychain. Only its public fingerprint accompanies the benchmark to prove it was not altered and to group your submissions."),
                            systemImage: "key.fill"
                        )
                        .padding(.vertical, 4)
                    } label: {
                        Label(loc.t("Firma e identidad", "Signature and identity"), systemImage: "signature")
                            .font(.headline)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label(loc.t("Por qué macOS podría pedir tu contraseña",
                                    "Why macOS might ask for your password"),
                              systemImage: "exclamationmark.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(loc.t("Las versiones actuales usan una firma de desarrollo temporal. Después de recompilar o actualizar, macOS puede pedir la contraseña de inicio de sesión para confirmar que la nueva compilación puede usar la clave existente.",
                                   "Current builds use a temporary development signature. After rebuilding or updating, macOS may ask for your login password to confirm that the new build may use the existing key."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(loc.t("Ese diálogo pertenece a macOS. ToshLLM nunca ve, recibe ni almacena tu contraseña.",
                                    "That prompt belongs to macOS. ToshLLM never sees, receives, or stores your password."),
                              systemImage: "hand.raised.fill")
                            .font(.callout)
                            .bold()
                        Text(loc.t("Cuando ToshLLM se distribuya con una firma Developer ID estable y notarizada por Apple, las actualizaciones normales conservarán la misma identidad y este aviso no debería repetirse.",
                                   "Once ToshLLM is distributed with a stable Developer ID signature and Apple notarization, normal updates will preserve the same identity and this prompt should no longer repeat."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.25)) }
                }
                .padding(24)
            }

            Divider()

            HStack(spacing: 12) {
                Label(loc.t("Nada se envía hasta tu confirmación final.",
                            "Nothing is uploaded until your final confirmation."),
                      systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(loc.t("Cancelar", "Cancel"), role: .cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Button(loc.t("Ejecutar benchmark y revisar", "Run benchmark and review"),
                       systemImage: "play.fill", action: continueSharing)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(minWidth: 580, idealWidth: 640, maxWidth: 700,
               minHeight: 620, idealHeight: 700, maxHeight: 820)
    }

    private func continueSharing() {
        dismiss()
        onContinue()
    }
}

