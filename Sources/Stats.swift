import Foundation
import IOKit

/// Polls GPU memory statistics directly from the IOAccelerator registry —
/// no process spawning, just an in-process IOKit query.
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
            guard let stats = Self.readAcceleratorStats() else { return }
            await MainActor.run { [weak self] in
                self?.usedMB = stats.used / 1_048_576
                self?.freeMB = stats.free / 1_048_576
            }
        }
    }

    /// Reads inUse/free VRAM bytes from the first accelerator that reports them.
    nonisolated private static func readAcceleratorStats() -> (used: Double, free: Double)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = unmanaged?.takeRetainedValue() as? [String: Any] else { continue }

            // The statistics live either at the top level or inside
            // "PerformanceStatistics" depending on the driver.
            let sources: [[String: Any]] = [props] +
                ((props["PerformanceStatistics"] as? [String: Any]).map { [$0] } ?? [])

            for dict in sources {
                if let used = (dict["inUseVidMemoryBytes"] as? NSNumber)?.doubleValue,
                   let free = (dict["vramFreeBytes"] as? NSNumber)?.doubleValue,
                   used + free > 0 {
                    return (used, free)
                }
            }
        }
        return nil
    }
}
