// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI

/// Menu-bar presence, as AppKit. `MenuBarExtra` is macOS 13 and cannot be
/// back-deployed, so the same `MenuBarView` is hosted in an `NSPopover` behind an
/// `NSStatusItem`, and the icon is drawn from the same state machine `MenuBarLabel`
/// uses.
final class MenuBarItemController {
    static let shared = MenuBarItemController()

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables: [AnyCancellable] = []
    private var defaultsObserver: NSObjectProtocol?

    private let obj = AppObjects.shared

    func start() {
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView()
            .environmentObject(obj.server)
            .environmentObject(obj.manager)
            .environmentObject(obj.loc)
            .environmentObject(obj.vram))

        sync()
        // The setting is an @AppStorage switch in the configuration window; the
        // status item has to follow it while the app runs.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }

        for source in [obj.server.objectWillChange, obj.vram.objectWillChange, obj.loc.objectWillChange] {
            cancellables.append(source.sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshLabel() }
            })
        }
    }

    func stop() {
        if let observer = defaultsObserver { NotificationCenter.default.removeObserver(observer) }
        defaultsObserver = nil
        cancellables.removeAll()
        setItem(nil)
    }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.menuBarIcon) as? Bool ?? true
    }

    private func sync() {
        guard enabled else { setItem(nil); return }
        if item == nil {
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            status.button?.action = #selector(toggle(_:))
            status.button?.target = self
            setItem(status)
        }
        refreshLabel()
    }

    private func setItem(_ newItem: NSStatusItem?) {
        if let old = item, old !== newItem { NSStatusBar.system.removeStatusItem(old) }
        item = newItem
    }

    private func refreshLabel() {
        // A hop, not a direct call: the state behind the icon lives on @MainActor
        // controllers and Swift 5.7 will not let this AppKit callback read them.
        Task { @MainActor [weak self] in self?.drawLabel() }
    }

    @MainActor
    private func drawLabel() {
        guard let button = item?.button else { return }
        let state = obj.server.state
        let symbol: String
        switch state {
        case .running: symbol = "cpu.fill"
        case .starting: symbol = "clock"
        case .failed: symbol = "exclamationmark.triangle.fill"
        case .stopped: symbol = "cpu"
        }
        let title: String
        switch state {
        case .running: title = obj.loc.t("ToshLLM: servidor activo", "ToshLLM: server running")
        case .starting: title = obj.loc.t("ToshLLM: iniciando", "ToshLLM: starting")
        case .failed: title = obj.loc.t("ToshLLM: el motor falló", "ToshLLM: the engine failed")
        case .stopped: title = obj.loc.t("ToshLLM: servidor parado", "ToshLLM: server stopped")
        }
        let showPercent = (UserDefaults.standard.string(forKey: SettingsKeys.menuBarGPU) ?? "panel") == "icon"
            && obj.vram.totalMB > 0
        let text = showPercent ? "\(Int(obj.vram.fraction * 100))%" : title
        button.image = symbolImage(symbol)
        button.imagePosition = showPercent ? .imageTrailing : .imageOnly
        if showPercent { button.title = " " + text }
        button.toolTip = title
    }

    private func symbolImage(_ name: String) -> NSImage? {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            image.isTemplate = true
            return image
        }
        return NSImage(named: NSImage.statusAvailableName)
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
