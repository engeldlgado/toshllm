import Foundation

enum GPUArchitectureClassifier {
    static func architecture(for name: String) -> String? {
        let normalized = name.lowercased().replacingOccurrences(of: "™", with: "")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        if let apple = appleArchitecture(in: normalized) { return apple }
        if let amd = amdArchitecture(in: normalized) { return amd }
        if let nvidia = nvidiaArchitecture(in: normalized) { return nvidia }
        if let intel = intelArchitecture(in: normalized) { return intel }
        return nil
    }

    private static func appleArchitecture(in value: String) -> String? {
        guard value.contains("apple") else { return nil }
        if value.range(of: #"\bm[1-9]\b"#, options: .regularExpression) != nil {
            return "Apple Silicon"
        }
        return value.contains("gpu") ? "Apple Silicon" : nil
    }

    private static func amdArchitecture(in value: String) -> String? {
        guard value.contains("amd") || value.contains("radeon") || value.contains("instinct") || value.contains("firepro") else {
            return nil
        }
        if value.contains("firepro") { return "GCN / Vega" }

        if let instinct = number(in: value, pattern: #"\bmi\s*(\d{2,3})[a-z]*\b"#) {
            if instinct >= 350 { return "CDNA 4" }
            if instinct >= 300 { return "CDNA 3" }
            if instinct >= 200 { return "CDNA 2" }
            if instinct >= 100 { return "CDNA 1" }
            if instinct >= 50 { return "GCN / Vega" }
        }

        if value.range(of: #"radeon\s+(?:ai\s+pro\s+)?r9\d{3}"#, options: .regularExpression) != nil {
            return "RDNA 4"
        }
        if let mobile = number(in: value, pattern: #"radeon\s+(\d{3,4})[ms]\b"#) {
            if mobile >= 8000 { return "RDNA 3.5" }
            if mobile >= 700 { return mobile >= 800 ? "RDNA 3.5" : mobile >= 700 ? "RDNA 3" : nil }
            if mobile >= 600 { return "RDNA 2" }
        }
        if value.contains("vega") || value.contains("radeon vii") { return "GCN / Vega" }

        if let rx = number(in: value, pattern: #"\brx\s*(\d{3,4})\b"#) {
            if rx >= 9000 { return "RDNA 4" }
            if rx >= 7000 { return "RDNA 3" }
            if rx >= 6000 { return "RDNA 2" }
            if rx >= 5000 { return "RDNA 1" }
            if rx >= 400 { return "GCN / Vega" }
        }
        if let workstation = number(in: value, pattern: #"\bw(\d{4})[a-z]*\b"#) {
            if workstation >= 9000 { return "RDNA 4" }
            if workstation >= 7000 { return "RDNA 3" }
            if workstation >= 6000 { return "RDNA 2" }
            if workstation >= 5000 { return "RDNA 1" }
        }
        if let radeonPro = number(in: value, pattern: #"radeon\s+pro\s+(\d{3,4})"#) {
            return radeonPro >= 5000 ? "RDNA 1" : "GCN / Vega"
        }
        if value.range(of: #"\br[579]\s"#, options: .regularExpression) != nil {
            return "GCN / Vega"
        }
        return nil
    }

    private static func nvidiaArchitecture(in value: String) -> String? {
        guard value.contains("nvidia") || value.contains("geforce") || value.contains("quadro") || value.contains("tesla") else {
            return nil
        }

        if value.contains("blackwell") || value.range(of: #"\brtx\s+pro\s+\d{4}"#, options: .regularExpression) != nil {
            return "Blackwell"
        }
        if value.contains("ada") { return "Ada Lovelace" }
        if value.range(of: #"\brtx\s+a\d{4}\b"#, options: .regularExpression) != nil { return "Ampere" }
        if value.range(of: #"\bquadro\s+rtx\b"#, options: .regularExpression) != nil { return "Turing" }
        if let rtx = number(in: value, pattern: #"\brtx\s*(\d{4})\b"#) {
            if rtx >= 5000 && rtx < 6000 { return "Blackwell" }
            if rtx >= 4000 && rtx < 5000 { return "Ada Lovelace" }
            if rtx >= 3000 && rtx < 4000 { return "Ampere" }
            if rtx >= 2000 && rtx < 3000 { return "Turing" }
        }
        if let gtx = number(in: value, pattern: #"\bgtx\s*(\d{3,4})\b"#) {
            if gtx >= 1600 { return "Turing" }
            if gtx >= 1000 { return "Pascal" }
            if gtx >= 900 { return "Maxwell" }
            if gtx >= 600 { return "Kepler" }
        }
        if value.range(of: #"\b(?:gb|b)(?:100|200|300)\b"#, options: .regularExpression) != nil { return "Blackwell" }
        if value.range(of: #"\b(?:gh|h)(?:100|200)\b"#, options: .regularExpression) != nil { return "Hopper" }
        if value.range(of: #"\b(?:a100|a40|a30|a10)\b"#, options: .regularExpression) != nil { return "Ampere" }
        if value.range(of: #"\bl(?:4|20|40)\b"#, options: .regularExpression) != nil { return "Ada Lovelace" }
        if value.range(of: #"\b(?:t4|titan\s+rtx)\b"#, options: .regularExpression) != nil { return "Turing" }
        if value.range(of: #"\bv100\b"#, options: .regularExpression) != nil { return "Volta" }
        if value.range(of: #"\bp(?:100|40|4)\b"#, options: .regularExpression) != nil { return "Pascal" }
        return nil
    }

    private static func intelArchitecture(in value: String) -> String? {
        guard value.contains("intel") || value.contains("arc") else { return nil }
        if value.range(of: #"\barc(?:\s+pro)?\s+b\d{2,3}\b"#, options: .regularExpression) != nil { return "Xe2 / Battlemage" }
        if value.range(of: #"\barc(?:\s+pro)?\s+a\d{2,3}\b"#, options: .regularExpression) != nil { return "Xe HPG / Alchemist" }
        if value.contains("iris xe") { return "Xe LP" }
        return nil
    }

    private static func number(in value: String, pattern: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return Int(value[range])
    }
}
