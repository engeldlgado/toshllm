// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AddedServerOverview: View {
    @ObservedObject var server: ServerController
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var manager: ServerManager
    @EnvironmentObject private var control: ControlPanelState
    @State private var configuring = false

    var body: some View {
        VStack(spacing: 12) {
            if configuring {
                ServerConfigurationBackButton { configuring = false }
                AddedServerCard(c: server)
            } else {
                ServerOverviewView(server: server, configure: {
                    control.focusServer(server.id)
                    configuring = true
                }, onDelete: deleteServer)
            }
        }
    }

    private func deleteServer() {
        manager.removeServer(server.id)
    }
}
