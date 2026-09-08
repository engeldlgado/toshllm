// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SidebarServerRow: View {
    @ObservedObject var server: ServerController
    @EnvironmentObject private var control: ControlPanelState
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var manager: ServerManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""

    var body: some View {
        let settings = server.effectiveSettings()
        let path = server.profile == nil ? modelPath : settings.modelPath
        HStack(spacing: 4) {
            Button {
                selectServer()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: server.state == .running ? "circle.fill" : "circle")
                        .font(.system(size: 9)).foregroundStyle(server.state == .running ? .green : .secondary)
                    Text(path.isEmpty ? manager.displayName(for: server, loc: loc) : ModelName.forPath(path).title)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if server.profile != nil {
                ServerDeleteButton(presentation: .icon) { manager.removeServer(server.id) }
                    .padding(.trailing, 8)
            }
        }
        .background(control.section == .dashboard && control.serverAnchor == server.id ? WorkspaceStyle.inset : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .help(manager.displayName(for: server, loc: loc))
        .accessibilityAddTraits(control.section == .dashboard && control.serverAnchor == server.id ? .isSelected : [])
    }

    private func selectServer() {
        let select = { control.focusServer(server.id) }
        if reduceMotion { select() } else { withAnimation(.snappy(duration: 0.2), select) }
    }
}
