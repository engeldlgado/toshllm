// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One option per row: glyph, label, control. Rows carry their own surface so a
/// group reads as a single card instead of the platform form's grouped look.
struct SettingsRow<Control: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var help: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(WorkspaceStyle.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(WorkspaceStyle.border))
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            control
                .frame(minHeight: 26, alignment: .center)
        }
        .padding(.leading, 14)
        .padding(.vertical, 7)
        .modifier(OptionalInfoTip(text: help))
        .padding(.trailing, 14)
        .frame(minHeight: 42)
    }
}

/// Rows without help text must not reserve an ⓘ slot, so the wrapper is conditional.
private struct OptionalInfoTip: ViewModifier {
    let text: String?

    @ViewBuilder func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.infoTip(text, revealOnHover: true)
        } else {
            content
        }
    }
}

/// Keeps keystrokes local to the field. The persisted binding changes only when
/// editing ends, avoiding a rebuild of a large Settings category on every key.
struct DeferredSettingsTextField: View {
    @Binding var text: String
    let placeholder: String
    var prompt: String? = nil
    var width: CGFloat? = nil
    var monospaced = false

    @State private var draft: String
    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>, prompt: String? = nil,
         width: CGFloat? = nil, monospaced: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.prompt = prompt
        self.width = width
        self.monospaced = monospaced
        self._draft = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        TextField(placeholder, text: $draft,
                  prompt: prompt.map { Text(verbatim: $0) })
            .font(monospaced ? .system(.caption, design: .monospaced) : .body)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, active in if !active { commit() } }
            .onChange(of: text) { _, value in if !focused { draft = value } }
            .workspaceTextField(width: width)
    }

    private func commit() {
        guard draft != text else { return }
        text = draft
    }
}

/// Numeric sibling of the deferred field. Typing into a value backed by
/// UserDefaults writes on every keystroke, which redraws every view watching
/// that key, so the value is only committed on submit or when focus leaves.
struct DeferredNumberField<Value: LosslessStringConvertible & Equatable>: View {
    @Binding var value: Value
    let placeholder: String
    var width: CGFloat? = nil

    @State private var draft: String
    @FocusState private var focused: Bool

    init(_ placeholder: String, value: Binding<Value>, width: CGFloat? = nil) {
        self.placeholder = placeholder
        self._value = value
        self.width = width
        self._draft = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        TextField(placeholder, text: $draft)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, active in if !active { commit() } }
            .onChange(of: value) { _, new in if !focused { draft = String(new) } }
            .workspaceTextField(width: width)
    }

    private func commit() {
        if let parsed = Value(draft) {
            if parsed != value { value = parsed }
        } else {
            draft = String(value)   // reject what does not parse
        }
    }
}

/// Numeric counterpart with immediate character filtering and deferred commit.
struct DeferredSettingsIntegerField: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var width: CGFloat = 92

    @State private var draft: String
    @FocusState private var focused: Bool

    init(value: Binding<Int>, in range: ClosedRange<Int>, width: CGFloat = 92) {
        self._value = value
        self.range = range
        self.width = width
        self._draft = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        TextField("", text: $draft)
            .focused($focused)
            .multilineTextAlignment(.trailing)
            .onChange(of: draft) { _, input in
                let filtered = input.filter(\.isNumber)
                if filtered != input { draft = filtered }
            }
            .onSubmit(commit)
            .onChange(of: focused) { _, active in if !active { commit() } }
            .onChange(of: value) { _, newValue in if !focused { draft = String(newValue) } }
            .workspaceTextField(width: width)
    }

    private func commit() {
        guard let parsed = Int(draft) else {
            draft = String(value)
            return
        }
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        draft = String(clamped)
        if clamped != value { value = clamped }
    }
}

/// Stacks rows into one card, drawing the hairline separators itself so callers
/// do not have to interleave them by hand.
struct SettingsRowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if #available(macOS 15, *) {
                Group(subviews: content) { rows in
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 { SettingsRowDivider() }
                        rows[index]
                    }
                }
            } else {
                content
            }
        }
        .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // A Shape in an overlay hit-tests its filled path, so an undecorated
        // border would sit on top of every row and eat hover and clicks.
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(WorkspaceStyle.border)
            .allowsHitTesting(false))
    }
}

/// Separator drawn inset so it lines up with the row labels, not the card edge.
struct SettingsRowDivider: View {
    var body: some View {
        Divider().opacity(0.5).padding(.leading, 52)
    }
}

/// Puts a row glyph in front of a platform control, so form-based sections match
/// the hand-built ones without rebuilding every control.
private struct SettingsGlyphModifier: ViewModifier {
    let icon: String

    func body(content: Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(WorkspaceStyle.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(WorkspaceStyle.border))
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            content
        }
        .frame(minHeight: 28, alignment: .center)
    }
}

/// Keeps the label at the app's standard body size while rendering only the
/// switch itself at the compact macOS size.
struct SettingsCompactToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
                .font(.body)
            Spacer(minLength: 10)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(minHeight: 28, alignment: .center)
    }
}

extension View {
    func settingsGlyph(_ icon: String) -> some View {
        modifier(SettingsGlyphModifier(icon: icon))
    }
}

/// The name field owns its own state so typing does not recompute the whole
/// Settings body, which probes the selected GGUF on every pass.
struct ProfileNameField: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        HStack(spacing: 10) {
            TextField(loc.t("Nombre del perfil (p. ej. Código, Chat rápido)",
                            "Profile name (e.g. Coding, Quick chat)"), text: $name)
                .workspaceTextField()
                .lineLimit(1)
                .onSubmit(save)
            Button(loc.t("Guardar actual", "Save current"), action: save)
                .glassButton()
                .fixedSize()
                .disabled(trimmed.isEmpty)
                .infoTip(loc.t("Guarda toda la configuración actual (modelo incluido) con este nombre.",
                               "Saves the entire current configuration (model included) under this name."))
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        profileStore.saveCurrent(name: trimmed)
        name = ""
    }
}

/// The switch used in settings rows. Rows no longer shrink their whole control,
/// because controlSize travels through the environment and shrank the text of
/// fields and pop-ups sitting in the same row.
struct SettingsToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}
