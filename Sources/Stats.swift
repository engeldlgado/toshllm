import Foundation

@MainActor
final class VRAMMonitor: ObservableObject {
    @Published var usedMB: Double = 0
    @Published var freeMB: Double = 0
    private var timer: Timer?

    var totalMB: Double { usedMB + freeMB }
    var fraction: Double { totalMB > 0 ? usedMB / totalMB : 0 }

    init() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            p.arguments = ["-r", "-c", "IOAccelerator", "-l"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return }

            func value(for key: String) -> Double? {
                guard let r = text.range(of: "\"\(key)\"=([0-9]+)", options: .regularExpression) else { return nil }
                let digits = text[r].split(separator: "=")[1]
                return Double(digits).map { $0 / 1_048_576 }
            }

            let used = value(for: "inUseVidMemoryBytes")
            let free = value(for: "vramFreeBytes")
            await MainActor.run { [weak self] in
                if let used { self?.usedMB = used }
                if let free { self?.freeMB = free }
            }
        }
    }
}
