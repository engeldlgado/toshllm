import SwiftUI
import CoreImage.CIFilterBuiltins

/// Donations popup: Binance Pay (bundled official QR) and USDT TRC-20 (generated QR).
struct DonateView: View {
    @EnvironmentObject var loc: Localizer
    @State private var method = 0
    @State private var copied = false

    var body: some View {
        VStack(spacing: 12) {
            Label(loc.t("Apoya el proyecto", "Support the project"), systemImage: "heart.fill")
                .font(.headline).foregroundStyle(.pink)
            Text(loc.isSpanish ? AppInfo.donateNoteES : AppInfo.donateNoteEN)
                .font(.callout).multilineTextAlignment(.center)
                .frame(width: 300)

            // Card-based sponsorship (Getly) is the easiest path, so it leads.
            Button {
                NSWorkspace.shared.open(URL(string: AppInfo.sponsorURL)!)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gift.fill").font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(loc.t("Conviértete en patrocinador", "Become a sponsor"))
                            .fontWeight(.semibold)
                        Text(loc.t("Apoya el desarrollo con tarjeta en Getly",
                                   "Support development by card on Getly"))
                            .font(.caption2).opacity(0.85)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.forward").font(.caption)
                }
                .padding(.vertical, 5).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.pink).controlSize(.large)
            .frame(width: 300)

            Text(loc.t("o con cripto", "or with crypto"))
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.top, 2)

            Picker("", selection: $method) {
                Text("Binance Pay").tag(0)
                Text("USDT (TRC-20)").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .onChange(of: method) { _, _ in copied = false }

            if method == 0 {
                binancePay
            } else {
                usdt
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var binancePay: some View {
        VStack(spacing: 10) {
            if let url = Bundle.main.url(forResource: "binance-qr", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 190, height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            copyRow(label: "Alias", value: AppInfo.binancePayID)
            Text(loc.t("Escanea desde la app de Binance para enviar, o busca el alias en Binance Pay.",
                       "Scan from the Binance app to send, or search the alias in Binance Pay."))
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var usdt: some View {
        VStack(spacing: 10) {
            if let qr = Self.qrImage(from: AppInfo.usdtTRC20) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
            copyRow(label: loc.t("Dirección", "Address"), value: AppInfo.usdtTRC20)
            Text(loc.t("⚠️ Envía solo USDT por la red TRON (TRC-20).",
                       "⚠️ Send only USDT on the TRON network (TRC-20)."))
                .font(.caption2).foregroundStyle(.orange)
        }
    }

    private func copyRow(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label + ":").foregroundStyle(.secondary).font(.caption)
            Text(value)
                .font(.system(size: 11, design: .monospaced).weight(.semibold))
                .lineLimit(1).truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Native QR code via CoreImage (no dependencies).
    static func qrImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
