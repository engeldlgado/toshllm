import AVKit
import SwiftUI

struct MediaAttachmentPreview: View {
    let attachment: ChatAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(attachment.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
            }
            if let player {
                NativePlayerView(player: player)
                    .frame(minWidth: 520, minHeight: attachment.mediaKind == "video" ? 340 : 110)
            } else {
                ProgressView()
            }
        }
        .padding()
        .task { prepare() }
        .onDisappear {
            player?.pause()
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        }
    }

    private func prepare() {
        guard let payload = attachment.base64Payload, let data = Data(base64Encoded: payload) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToshLLM-preview-\(UUID().uuidString).\(attachment.fenceHint)")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        temporaryURL = url
        player = AVPlayer(url: url)
    }
}

private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
