// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct WorkspaceSidebar: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var control: ControlPanelState
    @EnvironmentObject private var manager: ServerManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ToshLLMLogo(size: 38)
                Text("ToshLLM").font(.system(size: 21, weight: .semibold))
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 26)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    navigationRow(.dashboard)
                    Button { openWindow(id: "chat") } label: {
                        Label(loc.t("Chat y estudio", "Chat & Studio"), systemImage: "bubble.left.and.bubble.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    heading(loc.t("Biblioteca", "Library"))
                    navigationRow(.models)
                    navigationRow(.benchmarks)
                    heading(loc.t("Servidores", "Servers"))
                    ForEach(manager.servers, id: \.id) { server in
                        SidebarServerRow(server: server)
                    }
                    Button {
                        let server = manager.addServer(name: loc.t("Servidor %@", "Server %@", "\(manager.servers.count + 1)"), from: nil)
                        animate { control.focusServer(server.id) }
                    } label: {
                        Label(loc.t("Agregar servidor", "Add server"), systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    heading(loc.t("Herramientas", "Tools"))
                    navigationRow(.logs)
                    navigationRow(.docs)
                    Divider().padding(.vertical, 16).padding(.horizontal, 12)
                    navigationRow(.chatSettings)
                    navigationRow(.settings)
                    navigationRow(.about)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 16)
            }
            Text("LOCAL AI · macOS")
                .font(.system(size: 10, weight: .medium)).tracking(1.6)
                .foregroundStyle(.tertiary).padding(26)
        }
        // The split view supplies the native sidebar material on each macOS version.
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 11, weight: .medium)).tracking(1.2)
            .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 23).padding(.bottom, 7)
    }

    private func navigationRow(_ section: Section_) -> some View {
        let selected = control.section == section && (section != .dashboard || control.serverAnchor == nil)
        return Button {
            navigate(to: section)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? Color.appAccent : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(selected ? Color.appAccent.opacity(0.10) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(section.title(loc))
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(selected ? Color.appAccent.opacity(0.20) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func navigate(to section: Section_) {
        animate {
            control.serverAnchor = nil
            control.section = section
        }
    }

    private func animate(_ changes: @escaping () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.snappy(duration: 0.24), changes)
        }
    }
}
