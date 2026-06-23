import Foundation
import IOKit
import Metal

/// VRAM usage of a single GPU. `totalMB` comes from Metal (matches the figure on
/// the hardware card); `usedMB` from the IOAccelerator registry.
struct GPUStat: Identifiable {
    let id: Int          // Metal device index
    let name: String
    let usedMB: Double
    let totalMB: Double
    var freeMB: Double { max(0, totalMB - usedMB) }
    var fraction: Double { totalMB > 0 ? min(usedMB / totalMB, 1) : 0 }
}

/// Polls per-GPU VRAM directly from the IOAccelerator registry... no process
/// spawning, just an in-process IOKit query. Each Metal device is paired to its
/// accelerator node by registry ID, so two identical GPUs stay distinct.
@MainActor
final class VRAMMonitor: ObservableObject {
    @Published var gpus: [GPUStat] = []
    private var timer: Timer?

    // Aggregate across all GPUs, kept for the single-bar toolbar/menubar readouts.
    var usedMB: Double { gpus.reduce(0) { $0 + $1.usedMB } }
    var freeMB: Double { gpus.reduce(0) { $0 + $1.freeMB } }
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
            let stats = Self.readAllGPUs()
            await MainActor.run { [weak self] in self?.gpus = stats }
        }
    }

    /// One GPUStat per Metal device, pairing its name + total (from Metal) with the
    /// in-use bytes read from its accelerator node (located by registry ID).
    nonisolated private static func readAllGPUs() -> [GPUStat] {
        MTLCopyAllDevices().enumerated().map { i, dev in
            let totalMB = Double(dev.recommendedMaxWorkingSetSize) / 1_048_576
            let usedMB = usedBytes(forRegistryID: dev.registryID).map { $0 / 1_048_576 } ?? 0
            return GPUStat(id: i, name: dev.name, usedMB: usedMB, totalMB: totalMB)
        }
    }

    /// In-use VRAM bytes for the GPU with this Metal registry ID. Walks the
    /// accelerator subtree under the matching IOService node; the stat lives either
    /// at the top level or inside "PerformanceStatistics" depending on the driver.
    nonisolated private static func usedBytes(forRegistryID registryID: UInt64) -> Double? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IORegistryEntryIDMatching(registryID))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        let recursive = IOOptionBits(kIORegistryIterateRecursively)
        func search(_ key: String) -> Double? {
            guard let cf = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString,
                                                           kCFAllocatorDefault, recursive)
            else { return nil }
            return (cf as? NSNumber)?.doubleValue
        }

        if let used = search("inUseVidMemoryBytes") { return used }
        if let perf = IORegistryEntrySearchCFProperty(entry, kIOServicePlane,
                                                       "PerformanceStatistics" as CFString,
                                                       kCFAllocatorDefault, recursive) as? [String: Any],
           let used = (perf["inUseVidMemoryBytes"] as? NSNumber)?.doubleValue {
            return used
        }
        return nil
    }
}
