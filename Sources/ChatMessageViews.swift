import SwiftUI

// MARK: - Message bubble

struct MessageBubble: View, Equatable {
    let message: ChatMessage
    let streaming: Bool
    let liveSpeed: Double?
    let isLastAssistant: Bool
    let isLastUser: Bool
    let canRegenerate: Bool
    let onRegenerate: () -> Void
    let onEdit: () -> Void

    // Skips re-rendering finished bubbles while another one streams; without
    // this every visible bubble re-parses its markdown on each flush. The
    // closures are excluded: their behavior never varies for a given message.
    static func == (a: MessageBubble, b: MessageBubble) -> Bool {
        a.message == b.message && a.streaming == b.streaming
            && a.liveSpeed == b.liveSpeed && a.isLastAssistant == b.isLastAssistant
            && a.isLastUser == b.isLastUser && a.canRegenerate == b.canRegenerate
    }

    @EnvironmentObject var loc: Localizer
    @State private var thinkExpanded = false
    @State private var copied = false
    @State private var hovering = false

    private var isUser: Bool { message.role == "user" }

    /// One action affordance: an icon with a generous, fixed hit area so it is
    /// reliably clickable. Lives in a stable row under the bubble, not on hover.
    private func actionButton(_ icon: String, help: String,
                              tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// Copy / regenerate / edit, in a row beneath the message. Always present
    /// (not hover-gated) so every message — old ones included — stays
    /// reachable; the row just dims when the pointer is elsewhere.
    @ViewBuilder
    private var actionsRow: some View {
        HStack(spacing: 0) {
            actionButton(copied ? "checkmark" : "doc.on.doc",
                         help: loc.t("Copiar mensaje", "Copy message"),
                         tint: copied ? .green : .secondary) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    isUser ? message.content : message.parts.body, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            if isLastAssistant && canRegenerate {
                actionButton("arrow.clockwise",
                             help: loc.t("Regenerar respuesta", "Regenerate response"),
                             action: onRegenerate)
            }
            if isLastUser && canRegenerate {
                actionButton("pencil",
                             help: loc.t("Editar y reenviar", "Edit and resend"),
                             action: onEdit)
            }
        }
        .opacity(hovering ? 1 : 0.45)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 70) }

            if !isUser {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.pink)
                    .frame(width: 26, height: 26)
                    .background(.pink.opacity(0.15), in: Circle())
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                // header
                HStack(spacing: 8) {
                    Text(isUser ? loc.t("Tú", "You") : loc.t("Asistente", "Assistant"))
                        .font(.caption.weight(.medium))
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                    if let speed = message.genSpeed {
                        Text(String(format: "%.1f t/s", speed))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                // body
                VStack(alignment: .leading, spacing: 6) {
                    if let files = message.attachments, !files.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(files) { a in
                                Label(a.name, systemImage: "doc.text")
                                    .font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.quaternary.opacity(0.7), in: Capsule())
                                    .help(loc.t("Archivo enviado al modelo en este turno (~\(a.estimatedTokens) tokens).",
                                                "File sent to the model this turn (~\(a.estimatedTokens) tokens)."))
                            }
                        }
                    }
                    let parts = message.parts
                    let isThinkingLive = streaming && parts.body.isEmpty && parts.thinking != nil
                    if let think = parts.thinking, !think.isEmpty {
                        DisclosureGroup(isExpanded: $thinkExpanded) {
                            if thinkExpanded {
                                Text(think)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } label: {
                            Label(isThinkingLive ? loc.t("Razonando…", "Thinking…")
                                                 : loc.t("Razonamiento", "Reasoning"),
                                  systemImage: "brain")
                                .font(.caption).foregroundStyle(.blue)
                        }
                    }
                    if !parts.body.isEmpty || parts.thinking == nil {
                        RichText(text: isUser ? message.content : parts.body)
                    }
                    if streaming {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            if let speed = liveSpeed {
                                Text(String(format: "%.1f t/s", speed))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(isUser ? AnyShapeStyle(.tint.opacity(0.17)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                            in: RoundedRectangle(cornerRadius: 16))

                if !streaming { actionsRow }
            }

            if isUser {
                Image(systemName: "person.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            if !isUser { Spacer(minLength: 70) }
        }
        .onHover { hovering = $0 }
    }
}

/// Position of the transcript's bottom sentinel within the scroll viewport,
/// used to detect whether the user is at the bottom (auto-follow) or reading
/// older messages (no scroll hijacking).
struct BottomMarkerKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Hosts the in-progress assistant bubble: the only transcript view that
/// observes LiveStream, so per-flush updates re-render just this subtree.
struct StreamingBubble: View {
    @ObservedObject var live: LiveStream
    let message: ChatMessage
    let onGrow: () -> Void

    private var liveMessage: ChatMessage {
        var m = message
        if live.hasReasoning {
            m.content = "<think>" + live.displayedReasoning
                + (live.visibleText.isEmpty ? "" : "</think>" + live.visibleText)
        } else {
            m.content = live.visibleText
        }
        return m
    }

    var body: some View {
        StreamingMessageBubble(live: live, message: liveMessage)
            .onChange(of: live.visibleText) { _, _ in onGrow() }
    }
}

/// Streaming-only bubble. Reasoning stays collapsed and its growing text is
/// not published or laid out unless the user explicitly opens it.
struct StreamingMessageBubble: View {
    @ObservedObject var live: LiveStream
    let message: ChatMessage
    @EnvironmentObject var loc: Localizer

    private var reasoningBinding: Binding<Bool> {
        Binding(get: { live.reasoningExpanded },
                set: { live.setReasoningExpanded($0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 13))
                .foregroundStyle(.pink)
                .frame(width: 26, height: 26)
                .background(.pink.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(loc.t("Asistente", "Assistant")).font(.caption.weight(.medium))
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if live.hasReasoning {
                        DisclosureGroup(isExpanded: reasoningBinding) {
                            if live.reasoningExpanded {
                                Text(live.displayedReasoning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Label(live.visibleText.isEmpty ? loc.t("Razonando…", "Thinking…")
                                                               : loc.t("Razonamiento", "Reasoning"),
                                      systemImage: "brain")
                                if live.reasoningExpanded && live.visibleText.isEmpty {
                                    Text(loc.t("actualización ligera", "light updates"))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .font(.caption).foregroundStyle(.blue)
                        }
                    }

                    if !live.visibleText.isEmpty {
                        RichText(text: live.visibleText, streaming: true)
                    }

                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if let speed = live.speed {
                            Text(String(format: "%.1f t/s", speed))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            }

            Spacer(minLength: 70)
        }
    }
}

/// Observes LiveStream on its own so the t/s readout updates per flush
/// without re-evaluating the whole input bar.
struct LiveSpeedBadge: View {
    @ObservedObject var live: LiveStream

    var body: some View {
        if let speed = live.speed {
            Text(String(format: "%.1f t/s", speed))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.pink)
        }
    }
}

