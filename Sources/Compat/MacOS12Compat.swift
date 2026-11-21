// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Metal
import SwiftUI
import AppKit

// Back-deployment layer for macOS 12.
//
// The app is written against SwiftUI 4 (macOS 13+) / SwiftUI 5 (macOS 14+), but the
// oldest host it must run on is macOS 12, whose SwiftUI has no buildPartialBlock, no
// Layout protocol and none of the macOS 13 declarations as *available* symbols. The
// newest SDK here is 13.1, so those names exist but are availability-gated and an
// `if #available` does not help: the deployment target is 12.
//
// Everything below therefore shadows, rather than guards, the newer API: same name,
// our own parameter types, real behaviour where a substitute is possible and a
// deliberate no-op where the effect is cosmetic.

// MARK: - Duration and Task.sleep(for:)

struct ToshDuration: Equatable {
    let nanoseconds: UInt64

    init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }

    static func seconds(_ s: Double) -> ToshDuration { .init(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) }
    static func milliseconds(_ ms: Double) -> ToshDuration { .init(nanoseconds: UInt64(max(0, ms) * 1_000_000)) }
    static func microseconds(_ us: Double) -> ToshDuration { .init(nanoseconds: UInt64(max(0, us) * 1_000)) }
    static func nanoseconds(_ ns: Double) -> ToshDuration { .init(nanoseconds: UInt64(max(0, ns))) }

    private var secondsValue: Double { Double(nanoseconds) / 1_000_000_000 }

    var formatted: String { formatString(.minuteSecond) }
    func formatted(_ style: ToshTimeStyle) -> String { formatString(style.pattern) }
    func format(_ style: ToshTimeStyle) -> String { formatString(style.pattern) }

    private func formatString(_ pattern: ToshTimePattern) -> String {
        let total = Int(secondsValue.rounded())
        switch pattern {
        case .second:
            return String(format: "%.0fs", secondsValue)
        case .hourMinuteSecond:
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        default:
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }
}

struct ToshTimePattern: Equatable {
    static let second = ToshTimePattern()
    static let minuteSecond = ToshTimePattern()
    static let hourMinuteSecond = ToshTimePattern()
}

struct ToshTimeStyle {
    let pattern: ToshTimePattern
    static func time(pattern: ToshTimePattern) -> ToshTimeStyle { .init(pattern: pattern) }
}

typealias Duration = ToshDuration

extension Task where Success == Void, Failure == Error {
    static func sleep(for duration: ToshDuration) async throws {
        // Task<Never, Never> is the only spelling whose generic arguments let
        // sleep(nanoseconds:) infer Success/Failure correctly on Swift 5.7.
        try await Task<Never, Never>.sleep(nanoseconds: duration.nanoseconds)
    }
}

// MARK: - Shape styles

// macOS 12 has no AnyShapeStyle, so the erasure the code needs is done by overloads
// that all collapse into Color, which is a ShapeStyle.
/// The hierarchical and tint styles only exist inside AnyShapeStyle on macOS 13.
/// These are the same labels resolved to the AppKit colours they stand for, so a
/// call site can write ToshStyle.tertiary.opacity(0.5) as a plain ShapeStyle.
enum ToshStyle {
    static var primary: Color { Color(nsColor: .labelColor) }
    static var secondary: Color { Color(nsColor: .secondaryLabelColor) }
    static var tertiary: Color { Color(nsColor: .tertiaryLabelColor) }
    static var quaternary: Color { Color(nsColor: .quaternaryLabelColor) }
    static var tint: Color { Color.accentColor }
}

// Colors and materials keep their own spelling, so AnyShapeStyle(x) still reads
// naturally wherever a concrete value is passed.
func ToshShape(_ color: Color) -> Color { color }
// The gated AnyShapeStyle struct is still an overload candidate for a bare
// .regularMaterial, so materials get their own unambiguous spelling.
enum ToshMaterial {
    static let regular = Color(nsColor: .windowBackgroundColor).opacity(0.55)
}

extension Color {
    // Color.gradient is a hierarchical fill style; a flat color keeps the shape.
    var gradient: Color { self }
}

extension Color {
    /// In a generic ShapeStyle context Color.opacity and ShapeStyle.opacity are both
    /// viable; this pins the result to Color.
    func toshOpacity(_ value: Double) -> Color { opacity(value) }
}

// MARK: - onChange(of:initial:_:) and the zero-parameter form

struct ToshOnChange<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void
    @State private var previous: Value?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if previous == nil {
                    previous = value
                    if initial { action(value, value) }
                }
            }
            .onChange(of: value, perform: { newValue in
                let old = previous ?? newValue
                previous = newValue
                action(old, newValue)
            })
    }
}

extension View {
    func onChange<Value: Equatable>(of value: Value, initial: Bool = false,
                                    _ action: @escaping (Value, Value) -> Void) -> some View {
        modifier(ToshOnChange(value: value, initial: initial, action: action))
    }

    func onChange<Value: Equatable>(of value: Value, initial: Bool = false,
                                    _ action: @escaping () -> Void) -> some View {
        modifier(ToshOnChange(value: value, initial: initial) { _, _ in action() })
    }
}

// MARK: - Button(title, systemImage:)

extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ titleKey: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.init(action: action) { Label(titleKey, systemImage: systemImage) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, systemImage: String, action: @escaping () -> Void) {
        self.init(action: action) { Label(title, systemImage: systemImage) }
    }

    init(_ titleKey: LocalizedStringKey, systemImage: String, role: ButtonRole?,
         action: @escaping () -> Void) {
        self.init(role: role, action: action) { Label(titleKey, systemImage: systemImage) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, systemImage: String, role: ButtonRole?,
         action: @escaping () -> Void) {
        self.init(role: role, action: action) { Label(title, systemImage: systemImage) }
    }
}

// MARK: - Containers that are newer than the host

/// macOS 12 has no Layout protocol, so ViewThatFits cannot measure its candidates;
/// a shim that kept them all visible drew the content twice. ToshAdaptive switches
/// on the width the roomy branch was designed to need instead.
struct ToshAdaptive<Wide: View, Narrow: View>: View {
    let minWidth: CGFloat
    @ViewBuilder var wide: Wide
    @ViewBuilder var narrow: Narrow
    @State private var wideFits = true

    init(minWidth: CGFloat, @ViewBuilder wide: () -> Wide, @ViewBuilder narrow: () -> Narrow) {
        self.minWidth = minWidth
        self.wide = wide()
        self.narrow = narrow()
    }

    var body: some View {
        Group {
            if wideFits {
                wide
            } else {
                narrow
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            wideFits = width >= minWidth
        }
    }
}

/// macOS 12 has no Layout protocol. An adaptive grid flows the same chips onto
/// extra rows; the tradeoff is uniform column widths instead of tight packing.
struct ToshFlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 260),
                                      alignment: .leading)],
                  alignment: .leading, spacing: spacing) { content }
    }
}

/// Wrapping chips. macOS 12 has no Layout protocol, so the reflow comes from an
/// adaptive grid, the same substitute ToshFlowLayout uses.
struct WrappingFilterLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 240),
                                      alignment: .leading)],
                  alignment: .leading, spacing: spacing) { content }
    }
}

struct ToshGrid<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }
    init(alignment: HorizontalAlignment? = nil, horizontalSpacing: CGFloat? = nil,
         verticalSpacing: CGFloat? = nil, @ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
    }
}

struct ToshGridRow<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) { content }
    }
}

typealias Grid<Content: View> = ToshGrid<Content>
typealias GridRow<Content: View> = ToshGridRow<Content>

struct ToshLabeled<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            content
        }
    }
}

typealias LabeledContent<Content: View> = ToshLabeled<Content>

struct ContentUnavailableView<Label: View, Description: View>: View {
    let label: Label
    let description: Description
    let actions: AnyView?

    init(@ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description) {
        self.label = label()
        self.description = description()
        self.actions = nil
    }

    init<A: View>(@ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description,
                  @ViewBuilder actions: () -> A) {
        self.label = label()
        self.description = description()
        self.actions = AnyView(actions())
    }

    init(label: Label, description: Description) {
        self.label = label
        self.description = description
        self.actions = nil
    }

    var body: some View {
        VStack(spacing: 8) {
            label
            description.font(.callout)
            if let actions { actions }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

extension ContentUnavailableView where Label == Text, Description == EmptyView {
    init(_ title: String) {
        self.init(label: Text(title), description: EmptyView())
    }
}

extension ContentUnavailableView where Label == Text, Description == Text {
    init(_ title: String, description: String) {
        self.init(label: Text(title), description: Text(description))
    }
}

extension ContentUnavailableView where Label == Image, Description == EmptyView {
    init(_ title: String, systemImage: String) {
        self.init(label: Image(systemName: systemImage), description: EmptyView())
    }
}

extension ContentUnavailableView where Label == Image, Description == Text {
    init(_ title: String, systemImage: String, description: String = "") {
        self.init(label: Image(systemName: systemImage), description: Text(description))
    }

    /// The macOS 14 spelling takes a Text. Disfavored so a plain string still picks
    /// the overload above instead of becoming ambiguous.
    @_disfavoredOverload
    init(_ title: String, systemImage: String, description: Text) {
        self.init(label: Image(systemName: systemImage), description: description)
    }

    static func search(text: String) -> ContentUnavailableView<Image, Text> {
        ContentUnavailableView(text, systemImage: "magnifyingglass",
                               description: "No results")
    }
}

// MARK: - NavigationSplitView

/// The app uses only the two-column form, so the third (primary detail) column of the
/// macOS 13 container is dropped and NavigationView supplies the same sidebar plus detail.
enum ToshSplitVisibility {
    case all, sidebarOnly, detailOnly
}

struct ToshSplitView<Sidebar: View, Detail: View>: View {
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail

    init(columnVisibility: Binding<ToshSplitVisibility>? = nil,
         @ViewBuilder sidebar: () -> Sidebar,
         @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.detail = detail()
    }

    init(@ViewBuilder sidebar: () -> Sidebar,
         @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        NavigationView {
            sidebar
            detail
        }
        .navigationViewStyle(.columns)
    }
}

typealias NavigationSplitView<Sidebar: View, Detail: View> = ToshSplitView<Sidebar, Detail>
typealias NavigationSplitViewVisibility = ToshSplitVisibility

// MARK: - Modifiers newer than the macOS 12 SDK

extension View {
    func scrollContentBackground(_ visibility: Visibility) -> some View { self }
    func scrollBounceBehavior(_ behavior: ToshScrollBounceBehavior,
                              axes: Axis.Set = .vertical) -> some View { self }
    func contentTransition(_ transition: AnyTransition) -> some View { self }
    func symbolEffect(_ effect: ToshSymbolEffect, delay: Double = 0,
                      options: ToshSymbolEffectOptions? = nil) -> some View { self }
    func symbolEffect(_ effect: ToshSymbolEffect,
                      options: ToshSymbolEffectOptions? = nil,
                      isActive: Bool) -> some View { self }
    func presentationCornerRadius(_ radius: CGFloat?) -> some View { self }
    // Only reached from the `if #available(macOS 15)` branch in ChatWindowChrome,
    // whose else path already returns self: the title bar is transparent here, so
    // there is no toolbar background to hide.
    func toolbarBackgroundVisibility(_ visibility: Visibility,
                                     for kind: ToshToolbarKind) -> some View { self }
    func formStyle(_ style: ToshFormStyle) -> some View { self }
    func scrollDisabled(_ disabled: Bool) -> some View { self }
    // Real substitute: the limit itself is older API; only the reserved space is
    // missing, so the text is capped but its height can still settle.
    func lineLimit(_ lineNumber: Int?, reservesSpace: Bool = false) -> some View {
        lineLimit(lineNumber)
    }
    // Real substitute: macOS 12 has no column-width API, but the split view honors
    // the width constraints the sidebar content itself carries.
    func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat,
                                        max: CGFloat? = nil) -> some View {
        frame(minWidth: min, idealWidth: ideal, maxWidth: max)
    }
    // Real substitute: a tracking view behind the content reports every move, and it
    // opts out of hit testing so the drag the content itself handles keeps working.
    func onContinuousHover(perform action: @escaping (ContinuousHoverTracker.HoverPhase) -> Void) -> some View {
        background(ContinuousHoverTracker(onChange: action))
    }

    // Real substitute: the closure only needs the frame, which a background
    // GeometryReader can observe through onChange.
    func onGeometryChange<Subject: Equatable>(for: Subject.Type,
                                              of transform: @escaping (GeometryProxy) -> Subject,
                                              action: @escaping (Subject) -> Void) -> some View {
        background(GeometryReader { proxy in
            Color.clear
                .onAppear { action(transform(proxy)) }
                .onChange(of: transform(proxy), initial: false) { _, newValue in action(newValue) }
        })
    }
}

struct ToshScrollBounceBehavior {
    static let basedOnSize = ToshScrollBounceBehavior()
    static let always = ToshScrollBounceBehavior()
}

struct ToshSymbolEffect {
    static let replace = ToshSymbolEffect()
    static let pulse = ToshSymbolEffect()
    static let variableColor = ToshSymbolEffect()
    static let bounce = ToshSymbolEffect()
    static let wiggle = ToshSymbolEffect()
}

struct ToshSymbolEffectOptions {
    static let automatic = ToshSymbolEffectOptions()
    static let repeating = ToshSymbolEffectOptions()
}

struct ToshToolbarKind {
    static let windowToolbar = ToshToolbarKind()
}

struct ToshFormStyle {
    static let grouped = ToshFormStyle()
    static let columnsInheritanceDisabled = ToshFormStyle()
}

// MARK: - containerRelativeFrame

extension View {
    // The two call sites ask for a fraction of the container width, which is what an
    // flexible max width already gives when the item is the only child of the page.
    func containerRelativeFrame(_ axes: Axis.Set, alignment: Alignment = .center,
                                _ length: @escaping (CGFloat, ToshProposedViewSize) -> CGFloat) -> some View {
        frame(maxWidth: .infinity, alignment: alignment == .center ? .center : alignment)
    }

    func containerRelativeFrame(_ axes: Axis.Set, count: Int = 1, span: Int = 1,
                                spacing: CGFloat = 0,
                                alignment: Alignment = .center,
                                _ length: @escaping (CGFloat, ToshProposedViewSize) -> CGFloat) -> some View {
        frame(maxWidth: .infinity)
    }
}

struct ToshProposedViewSize {
    static let unspecified = ToshProposedViewSize()
}

typealias ProposedViewSize = ToshProposedViewSize

extension AnyTransition {
    static func symbolEffect(_ effect: ToshSymbolEffect) -> AnyTransition { .opacity }
}

// MARK: - Menus

extension Menu where Label == SwiftUI.Label<Text, Image> {
    init(_ title: LocalizedStringKey, systemImage: String,
         @ViewBuilder content: () -> Content) {
        self.init(content: content) { Label(title, systemImage: systemImage) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, systemImage: String,
                            @ViewBuilder content: () -> Content) {
        self.init(content: content) { Label(title, systemImage: systemImage) }
    }
}

struct ToshRoundedRectangle: InsettableShape {
    var cornerRadius: CGFloat
    var style: RoundedCornerStyle = .continuous
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: cornerRadius, style: style)
            .path(in: rect.insetBy(dx: insetAmount, dy: insetAmount))
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    var anchorPoint: CGPoint { CGPoint(x: 0.5, y: 0.5) }
}

extension Shape where Self == ToshRoundedRectangle {
    static func rect(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) -> ToshRoundedRectangle {
        ToshRoundedRectangle(cornerRadius: cornerRadius, style: style)
    }
}

// MARK: - openWindow

struct ToshOpenWindow {
    func callAsFunction(id: String) { ToshWindowRegistry.shared.open(id: id) }
    func callAsFunction<Value: Hashable>(value: Value) { ToshWindowRegistry.shared.open(value: value) }
    func callAsFunction(id: String, value: AnyHashable) { ToshWindowRegistry.shared.open(id: id) }
}

extension EnvironmentValues {
    var openWindow: ToshOpenWindow {
        get { ToshOpenWindow() }
        set {}
    }
}

/// Touched only from the main thread (all callers are UI actions), so it needs no
/// actor: Swift 5.7 cannot isolate the nonisolated `callAsFunction` shim anyway.
final class ToshWindowRegistry {
    static let shared = ToshWindowRegistry()

    private var byID: [String: NSWindow] = [:]
    private var openRequested: Set<String> = []
    private var configured: Set<ObjectIdentifier> = []
    private var factories: [String: () -> NSWindow] = [:]

    func wasRequested(id: String) -> Bool { openRequested.contains(id) }

    /// macOS 12 only renders the first WindowGroup at launch, so a secondary scene has
    /// no window to bring forward until SwiftUI feels like creating one. Scenes that
    /// must open on demand register a factory here instead and get built on request.
    func setFactory(id: String, _ make: @escaping () -> NSWindow) { factories[id] = make }

    /// Runs once per window: SwiftUI is still laying the window out when it first
    /// attaches, so everything is applied a queue hop later. The default content
    /// size has to be forced here because on macOS 12 there is no Scene-level
    /// default size and the window otherwise opens at the view's minimum. Title-bar
    /// chrome is not touched: each window applies its own (ChatWindowChrome).
    func configure(_ window: NSWindow, id: String, size: CGSize?,
                   hideUntilRequested: Bool) {
        window.identifier = NSUserInterfaceItemIdentifier(id)
        byID[id] = window
        guard configured.insert(ObjectIdentifier(window)).inserted else { return }
        DispatchQueue.main.async {
            if let size = size {
                window.setContentSize(size)
                window.center()
            }
            if hideUntilRequested, !self.openRequested.contains(id) {
                window.orderOut(nil)
            }
        }
    }

    func open(id: String) {
        openRequested.insert(id)
        if byID[id] == nil, let make = factories[id] {
            let window = make()
            window.identifier = NSUserInterfaceItemIdentifier(id)
            byID[id] = window
        }
        guard let window = byID[id] else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func open<Value: Hashable>(value: Value) {
        let key = String(describing: value)
        if byID[key] != nil { open(id: key); return }
        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// The window only exists once AppKit has attached the view, which happens after
/// `makeNSView` returns, so the accessor waits for `viewDidMoveToWindow` instead of
/// polling `view.window`.
final class ToshWindowProbeView: NSView {
    var onAttach: ((NSWindow) -> Void)?
    private var notified = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !notified, let window = window else { return }
        notified = true
        onAttach?(window)
    }
}

struct ToshWindowAccessor: NSViewRepresentable {
    let id: String
    let size: CGSize?
    let hideUntilRequested: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ToshWindowProbeView(frame: .zero)
        view.onAttach = { [id, size, hideUntilRequested] window in
            ToshWindowRegistry.shared.configure(window, id: id, size: size,
                                                hideUntilRequested: hideUntilRequested)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func toshWindowID(_ id: String, size: CGSize? = nil,
                      hideUntilRequested: Bool = false) -> some View {
        background(ToshWindowAccessor(id: id, size: size,
                                      hideUntilRequested: hideUntilRequested))
    }
}

// MARK: - Animations

extension Animation {
    static func snappy(duration: Double) -> Animation {
        .spring(response: duration, dampingFraction: 0.86)
    }

    static func snappy(duration: Double, extraBounce: Double) -> Animation {
        .spring(response: duration, dampingFraction: max(0.2, 0.86 - extraBounce))
    }

    /// macOS 14 retuned the spring presets in terms of a period and a bounce. The
    /// Double parameter keeps this a real overload instead of a redeclaration of the
    /// gated `Duration` version.
    static func spring(duration: Double, bounce: Double = 0, blendDuration: Double = 0) -> Animation {
        .spring(response: duration, dampingFraction: max(0.2, 0.86 - bounce * 0.7))
    }
}

// MARK: - String and Foundation helpers

extension String {
    func replacing(_ expression: String, with replacement: String,
                   maxReplacements: Int = .max) -> String {
        replacingOccurrences(of: expression, with: replacement, options: [], range: nil)
    }
}

extension URL {
    static var toshTemporaryDirectory: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }
}

// MARK: - Multiline text, indicators and pasteboard drops

extension View {
    // Real substitute: capping at the upper bound keeps long text from growing past
    // the row that sized for it; only the minimum reserve is missing.
    func lineLimit(_ limit: ClosedRange<Int>) -> some View { lineLimit(limit.upperBound) }
    // No older spelling exists, so the bars macOS 12 draws stay.
    func scrollIndicators(_ visibility: ToshScrollVisibility,
                          axes: Axis.Set = .vertical) -> some View { self }
}

enum ToshScrollVisibility { case automatic, visible, hidden }

extension URL {
    func appending(path: String) -> URL { appendingPathComponent(path) }
    func appending(path: String, directoryHint: ToshDirectoryHint) -> URL {
        appendingPathComponent(path)
    }
}

enum ToshDirectoryHint { case infer, shouldProcess, shouldNotProcess }

/// macOS 12 has no Transferable drop destination, but the pasteboard carries the
/// same payloads; the completion hop back to the main queue keeps the ordering.
private final class ToshDropBox<Item> {
    private let lock = NSLock()
    private var storage: [Item] = []
    var items: [Item] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func append(_ item: Item) {
        lock.lock(); storage.append(item); lock.unlock()
    }
}

private struct ToshDropTarget<Item, Content: View>: View {
    var content: Content
    let types: [String]
    let action: ([Item], CGPoint) -> Bool
    let isTargeted: (Bool) -> Void
    let decode: (NSItemProvider, @escaping (Item?) -> Void) -> Void

    @State private var targeted = false

    var body: some View {
        content
            .onDrop(of: types, isTargeted: $targeted) { providers, location in
                let box = ToshDropBox<Item>()
                let group = DispatchGroup()
                for provider in providers {
                    group.enter()
                    decode(provider) { item in
                        if let item { box.append(item) }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { _ = self.action(box.items, location) }
                return true
            }
            .onChange(of: targeted) { value in isTargeted(value) }
    }
}

extension View {
    func dropDestination(for type: URL.Type,
                         action: @escaping ([URL], CGPoint) -> Bool,
                         isTargeted: @escaping (Bool) -> Void = { _ in }) -> some View {
        ToshDropTarget<URL, Self>(content: self, types: ["public.file-url"], action: action,
                                  isTargeted: isTargeted) { provider, done in
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data {
                    done(URL(dataRepresentation: data, relativeTo: nil))
                } else {
                    done(item as? URL)
                }
            }
        }
    }

    func dropDestination(for type: String.Type,
                         action: @escaping ([String], CGPoint) -> Bool,
                         isTargeted: @escaping (Bool) -> Void = { _ in }) -> some View {
        ToshDropTarget<String, Self>(content: self, types: ["public.utf8-plain-text"],
                                     action: action,
                                     isTargeted: isTargeted) { provider, done in
            provider.loadObject(ofClass: NSString.self) { value, _ in
                done(value as? String)
            }
        }
    }
}

// MARK: - Key presses

struct ToshKeyPress {
    var modifiers: ModifierFlags

    struct ModifierFlags: OptionSet {
        let rawValue: Int
        static let command = ModifierFlags(rawValue: 1 << 0)
        static let shift = ModifierFlags(rawValue: 1 << 1)
        static let option = ModifierFlags(rawValue: 1 << 2)
        static let control = ModifierFlags(rawValue: 1 << 3)
    }
}

enum ToshKeyPressAction { case ignored, handled }

struct ToshKeyPressPhases: OptionSet {
    let rawValue: Int
    static let down = ToshKeyPressPhases(rawValue: 1 << 0)
    static let up = ToshKeyPressPhases(rawValue: 1 << 1)
}

enum ToshKeyEquivalent {
    case return_, escape, tab, delete, space, up, down, left, right

    var keyCode: Int? {
        switch self {
        case .return_: return 36
        case .escape: return 53
        case .tab: return 48
        case .delete: return 51
        case .space: return 49
        case .up: return 126
        case .down: return 125
        case .left: return 123
        case .right: return 124
        }
    }
}

extension ToshKeyEquivalent {
    static var `return`: ToshKeyEquivalent { .return_ }
}

/// Keys are watched only while the modified view is on screen, and only inside its
/// own window's text editor, so a key press elsewhere in the app is left alone.
private struct ToshKeyPressMonitor: NSViewRepresentable {
    let keyCode: Int?
    let action: (ToshKeyPress) -> ToshKeyPressAction

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Releasing the view releases the coordinator, which drops the monitor.
    final class Coordinator {
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        guard let keyCode else { return view }
        let handler = action
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == keyCode, event.window === view.window else { return event }
            guard (event.window?.firstResponder as? NSText)?.isEditable == true else { return event }
            let press = ToshKeyPress(modifiers: ToshModifierFlags.translate(event.modifierFlags))
            return handler(press) == .handled ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private enum ToshModifierFlags {
    static func translate(_ flags: NSEvent.ModifierFlags) -> ToshKeyPress.ModifierFlags {
        var out: ToshKeyPress.ModifierFlags = []
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.option) { out.insert(.option) }
        if flags.contains(.control) { out.insert(.control) }
        return out
    }
}

extension View {
    func onKeyPress(_ key: ToshKeyEquivalent? = nil, phases: ToshKeyPressPhases = .down,
                    action: @escaping (ToshKeyPress) -> ToshKeyPressAction) -> some View {
        background(ToshKeyPressMonitor(keyCode: key?.keyCode, action: action)
            .frame(width: 0, height: 0))
    }
}

// MARK: - Offscreen view rasterisation

/// macOS 12 has no ImageRenderer; caching an NSHostingView's display gives the
/// same bitmap, at the backing scale rather than an arbitrary one.
final class ToshImageRenderer<Content: View> {
    let content: Content
    var scale: CGFloat = 1

    init(content: Content) { self.content = content }

    var nsImage: NSImage? {
        let host = NSHostingView(rootView: content)
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 1 || size.height < 1 { size = host.frame.size }
        guard size.width >= 1, size.height >= 1 else { return nil }
        host.frame = NSRect(origin: .zero, size: size)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    var cgImage: CGImage? {
        guard let nsImage else { return nil }
        var rect = NSRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

typealias ImageRenderer<Content: View> = ToshImageRenderer<Content>

// MARK: - Metal

extension MTLGPUFamily {
    /// The .metal3 case is gated to macOS 13 but the family number is the same
    /// integer, and a pre-Metal-3 runtime simply answers false.
    static var toshMetal3: MTLGPUFamily { MTLGPUFamily(rawValue: 5001) ?? .mac2 }
}
