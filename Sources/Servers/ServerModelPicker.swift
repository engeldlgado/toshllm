// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ServerModelPicker: View {
    @ObservedObject var server: ServerController
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var manager: ServerManager
    @EnvironmentObject private var loc: Localizer
    @AppStorage(SettingsKeys.modelPath) private var globalModelPath = ""

    var prominent = false

    var body: some View {
        let path = server.profile == nil ? globalModelPath : server.effectiveSettings().modelPath
        Menu {
            Button(loc.t("Sin modelo", "No model")) { select("") }
            ForEach(models.modelGroups) { group in
                Section(group.isOther ? loc.t("Otros", "Others") : group.family) {
                    ForEach(group.models) { model in
                        Button { select(model.url.path) } label: {
                            if model.url.path == path {
                                Label(ModelName.forPath(model.url.path).display, systemImage: "checkmark")
                            } else {
                                Text(ModelName.forPath(model.url.path).display)
                            }
                        }
                    }
                }
            }
        } label: {
            Text(path.isEmpty ? loc.t("Elige un modelo", "Choose a model") : ModelName.forPath(path).title)
                .font(prominent ? .system(size: 19, weight: .semibold) : .body)
                .lineLimit(2)
        }
        .menuStyle(.borderlessButton)
        .disabled(server.state == .running || server.state == .starting)
        .accessibilityLabel(loc.t("Modelo de esta instancia", "Model for this instance"))
        .help(loc.t("Selecciona el modelo de este servidor. Detén esta instancia para cambiarlo.",
                    "Select this server’s model. Stop this instance to change it."))
    }

    private func select(_ path: String) {
        server.selectModel(path: path, ncmoe: Estimator.ncmoeForSelection(path: path, models: models.models))
        manager.persist()
    }
}
