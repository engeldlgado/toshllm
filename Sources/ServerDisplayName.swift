// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension ServerManager {
    func displayName(for server: ServerController, loc: Localizer) -> String {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else {
            return server.name
        }
        if index == 0 {
            return loc.t("Servidor principal", "Primary server")
        }

        let stored = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [#"^Servidor\s+(\d+)$"#, #"^Server\s+(\d+)$"#]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: stored, range: NSRange(stored.startIndex..., in: stored)),
                  let range = Range(match.range(at: 1), in: stored) else { continue }
            return loc.t("Servidor %@", "Server %@", String(stored[range]))
        }
        return stored.isEmpty ? loc.t("Servidor %@", "Server %@", String(index + 1)) : stored
    }
}
