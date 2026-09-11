// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Gives navigation destinations a stable, small identity. Live server metrics
/// can then update without recreating unrelated destination views.
struct WorkspaceDestinationView: View {
    let section: Section_
    let serverID: UUID?

    var body: some View {
        Group {
            switch section {
            case .dashboard, .chat: DashboardView()
            case .models: ModelsView()
            case .benchmarks: BenchmarksView()
            case .docs: DocsView()
            case .logs: LogsView()
            case .chatSettings: ChatSettingsView()
            case .settings: SettingsView()
            case .about: AboutView()
            }
        }
    }
}
