import SwiftUI

/// Flips a view vertically. Applied to the scroll view and each row, it inverts
/// the scroll (newest at the bottom) while keeping row content upright.
extension View {
    func flippedUpsideDown() -> some View {
        rotationEffect(.radians(.pi)).scaleEffect(x: -1, y: 1, anchor: .center)
    }
}

/// Header row for the collapsible reasoning section: brain icon, title and a
/// chevron that rotates with the open state.
func reasoningHeader(_ title: String, expanded: Bool) -> some View {
    HStack(spacing: 6) {
        Image(systemName: "brain")
        Text(title)
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 0 : -90))
    }
    .font(.caption)
    .foregroundStyle(.blue)
    .contentShape(Rectangle())
}

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
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 26, height: 26)
                    .background(Color.appAccent.opacity(0.15), in: Circle())
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
                    if let accept = message.mtpAccept {
                        Text("MTP \(Int((accept * 100).rounded()))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .help(loc.t("Aceptación de la predicción multi-token: qué fracción de los tokens que el cabezal MTP adelantó resultó correcta. Más alta = más aceleración, sin cambio de calidad.",
                                        "Multi-token prediction acceptance: the fraction of tokens the MTP head drafted that turned out right. Higher = more speedup, no quality change."))
                    }
                }

                // body
                VStack(alignment: .leading, spacing: 6) {
                    if let imgs = message.imageURIs, !imgs.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(imgs.enumerated()), id: \.offset) { _, uri in
                                if let img = NativeChatView.nsImage(fromDataURI: uri) {
                                    Image(nsImage: img).resizable().scaledToFill()
                                        .frame(width: 120, height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
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
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { thinkExpanded.toggle() }
                            } label: {
                                reasoningHeader(isThinkingLive ? loc.t("Razonando…", "Thinking…")
                                                               : loc.t("Razonamiento", "Reasoning"),
                                                expanded: thinkExpanded)
                            }
                            .buttonStyle(.plain)
                            if thinkExpanded {
                                Text(think)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
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
    @AppStorage(SettingsKeys.smoothTyping) private var smoothTyping = true

    // Open instantly (animating the large transcript's layout felt like a hang);
    // closing keeps its animation.
    private func toggleReasoning() {
        if live.reasoningExpanded {
            live.setReasoningExpanded(false)
        } else {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { live.setReasoningExpanded(true) }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.appAccent)
                .frame(width: 26, height: 26)
                .background(Color.appAccent.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(loc.t("Asistente", "Assistant")).font(.caption.weight(.medium))
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if live.hasReasoning {
                        VStack(alignment: .leading, spacing: 2) {
                            Button {
                                toggleReasoning()
                            } label: {
                                HStack(spacing: 6) {
                                    reasoningHeader(live.visibleText.isEmpty ? loc.t("Razonando…", "Thinking…")
                                                                             : loc.t("Razonamiento", "Reasoning"),
                                                    expanded: live.reasoningExpanded)
                                    if live.reasoningExpanded && live.visibleText.isEmpty {
                                        Text(loc.t("actualización ligera", "light updates"))
                                            .font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            // Collapsed live peek: a quiet two-line tail so the wait
                            // shows the model is actively thinking; fixed height.
                            if !live.reasoningExpanded, live.visibleText.isEmpty,
                               !live.reasoningTail.isEmpty {
                                Text(verbatim: live.reasoningTail)
                                    .font(.caption2.italic())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2, reservesSpace: true)
                                    .truncationMode(.head)
                                    .contentTransition(.opacity)
                                    .animation(.easeOut(duration: 0.28), value: live.reasoningTail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 7)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(.blue.opacity(0.35))
                                            .frame(width: 2)
                                            .padding(.vertical, 1)
                                    }
                                    .padding(.top, 1)
                            }
                            if live.reasoningExpanded {
                                Text(live.displayedReasoning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if !live.visibleText.isEmpty {
                        StreamingRichText(text: live.visibleText, smooth: smoothTyping)
                    }

                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        // Label the prefill phase so the pre-first-token wait reads
                        // as work, not a hang. Reasoning/answer have their own labels.
                        if !live.hasReasoning && live.visibleText.isEmpty {
                            PrefillStatusLabel(progress: live.prefillProgress)
                        }
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

/// Typewriter reveal: shows a steadily growing prefix of `text` so bursty tokens
/// read as smooth typing. Only the plain tail re-renders, so cost stays low. When
/// `smooth` is off, renders directly.
struct StreamingRichText: View {
    let text: String
    let smooth: Bool
    @State private var revealed = 0

    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if smooth {
                RichText(text: String(text.prefix(revealed)), streaming: true)
                    .onReceive(tick) { _ in
                        let target = text.count
                        guard revealed < target else { return }
                        // Ease-out catch-up so it never lags far behind fast generation.
                        revealed = min(target, revealed + max(1, (target - revealed) / 8))
                    }
                    .onChange(of: text) { _, newValue in
                        if revealed > newValue.count { revealed = newValue.count }
                    }
            } else {
                RichText(text: text, streaming: true)
            }
        }
    }
}

/// Prefill-phase status: a phrase that reflects how far prompt processing has
/// got. When the server reports progress the phrase tracks it (e.g. "Almost
/// there…" past 90%); otherwise it cycles on a timer.
struct PrefillStatusLabel: View {
    let progress: Double?
    @EnvironmentObject var loc: Localizer

    // Ordered by the progress at which each takes over.
    private let phrases: [(String, String)] = [
        ("Procesando el prompt…", "Processing the prompt…"),
        ("Leyendo el contexto…",  "Reading the context…"),
        ("Repasando el historial…", "Going over the history…"),
        ("Preparando la respuesta…", "Preparing the answer…"),
        ("Casi listo…", "Almost there…"),
    ]

    private func phraseIndex(for p: Double) -> Int {
        switch p {
        case ..<0.25: return 0
        case ..<0.50: return 1
        case ..<0.70: return 2
        case ..<0.90: return 3
        default:      return 4
        }
    }

    var body: some View {
        Group {
            if let p = progress {
                let i = phraseIndex(for: p)
                Text(loc.t(phrases[i].0, phrases[i].1))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: i)
            } else {
                TimelineView(.periodic(from: .now, by: 2.2)) { context in
                    let i = Int(context.date.timeIntervalSinceReferenceDate / 2.2) % phrases.count
                    Text(loc.t(phrases[i].0, phrases[i].1))
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.4), value: i)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
                .foregroundStyle(Color.appAccent)
        }
    }
}

