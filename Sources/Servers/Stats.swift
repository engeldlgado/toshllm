// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit
import Metal

/// VRAM usage of a single GPU. `totalMB` comes from Metal (matches the figure on
/// the hardware card); `usedMB` from the IOAccelerator registry.
struct GPUStat: Identifiable, Sendable, Equatable {
    let id: Int          // Metal device index
    let name: String
    let usedMB: Double
    let totalMB: Double
    /// Whole-device load reported by IOAccelerator. Some drivers omit it, so
    /// callers must keep the unavailable state instead of inventing a zero.
    var activityPercent: Double?
    var temperatureC: Double?
    var powerW: Double?
    var peerGroupID: UInt64 = 0
    var freeMB: Double { max(0, totalMB - usedMB) }
    var fraction: Double { totalMB > 0 ? min(usedMB / totalMB, 1) : 0 }
}

struct SystemTelemetrySample: Sendable, Equatable {
    var gpus: [GPUStat] = []
    var memoryUsedMB: Double = 0
    var memoryTotalMB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
}

/// Polls per-GPU VRAM directly from the IOAccelerator registry... no process
/// spawning, just an in-process IOKit query. Each Metal device is paired to its
/// accelerator node by registry ID, so two identical GPUs stay distinct.
@MainActor
final class VRAMMonitor: ObservableObject {
    @Published private(set) var sample = SystemTelemetrySample()
    private var timer: Timer?
    private var polls = 0
    private var rescanNext = false

    var gpus: [GPUStat] { sample.gpus }
    var memoryUsedMB: Double { sample.memoryUsedMB }
    var memoryTotalMB: Double { sample.memoryTotalMB }
    var memoryFraction: Double { memoryTotalMB > 0 ? min(memoryUsedMB / memoryTotalMB, 1) : 0 }
    var activityPercent: Double? { gpus.compactMap(\.activityPercent).max() }

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

    nonisolated static func snapshot() -> [GPUStat] { readAllGPUs(rescanDevices: true) }

    /// Re-enumerates on demand, for when the user plugs or unplugs an eGPU.
    func refreshDevices() { rescanNext = true; poll() }

    private func poll() {
        polls += 1
        // Enumerating Metal devices can take a multi-GPU Mac Pro down, so it runs
        // once and only again when the user asks for it.
        let rescan = polls == 1 || rescanNext
        rescanNext = false
        Task.detached(priority: .utility) {
            let stats = Self.readAllGPUs(rescanDevices: rescan)
            let memory = Self.readSystemMemory()
            let next = SystemTelemetrySample(gpus: stats,
                                             memoryUsedMB: memory.used,
                                             memoryTotalMB: memory.total)
            await MainActor.run { [weak self] in
                // Publishing an identical sample would invalidate every view that
                // draws a VRAM bar, three times a minute, for nothing.
                guard let self, self.sample != next else { return }
                self.sample = next
            }
        }
    }

    /// One GPUStat per Metal device, pairing its name + total (from Metal) with the
    /// in-use bytes read from its accelerator node (located by registry ID).
    nonisolated private static func readAllGPUs(rescanDevices: Bool) -> [GPUStat] {
        MetalDeviceCache.devices(rescan: rescanDevices).enumerated().map { i, dev in
            let totalMB = Double(dev.recommendedMaxWorkingSetSize) / 1_048_576
            let registry = registryStats(forRegistryID: dev.registryID)
            let usedMB = (registry.usedBytes ?? 0) / 1_048_576
            return GPUStat(id: i, name: dev.name, usedMB: usedMB, totalMB: totalMB,
                           activityPercent: registry.activityPercent,
                           temperatureC: registry.temperatureC,
                           powerW: registry.powerW,
                           peerGroupID: dev.peerGroupID)
        }
    }

    /// In-use VRAM bytes for the GPU with this Metal registry ID. Walks the
    /// accelerator subtree under the matching IOService node; the stat lives either
    /// at the top level or inside "PerformanceStatistics" depending on the driver.
    nonisolated private static func registryStats(forRegistryID registryID: UInt64)
        -> (usedBytes: Double?, activityPercent: Double?, temperatureC: Double?, powerW: Double?) {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IORegistryEntryIDMatching(registryID))
        guard entry != 0 else { return (nil, nil, nil, nil) }
        defer { IOObjectRelease(entry) }

        let recursive = IOOptionBits(kIORegistryIterateRecursively)
        func search(_ key: String) -> Double? {
            guard let cf = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString,
                                                           kCFAllocatorDefault, recursive)
            else { return nil }
            return (cf as? NSNumber)?.doubleValue
        }

        let perf = IORegistryEntrySearchCFProperty(entry, kIOServicePlane,
                                                    "PerformanceStatistics" as CFString,
                                                    kCFAllocatorDefault, recursive) as? [String: Any]
        func number(_ keys: [String]) -> Double? {
            for key in keys {
                if let value = (perf?[key] as? NSNumber)?.doubleValue { return value }
                if let value = search(key) { return value }
            }
            return nil
        }
        return (number(["inUseVidMemoryBytes"]),
                number(["Device Utilization %", "GPU Activity(%)"]),
                number(["Temperature(C)"]),
                number(["Total Power(W)"]))
    }

    /// Active + wired + compressed pages gives a stable, useful approximation
    /// of memory currently occupied. It intentionally excludes inactive/cache
    /// pages that macOS can reclaim immediately.
    nonisolated private static func readSystemMemory() -> (used: Double, total: Double) {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pages = UInt64(info.active_count) + UInt64(info.wire_count)
            + UInt64(info.compressor_page_count)
        return (Double(pages * UInt64(pageSize)) / 1_048_576, total)
    }
}

/// The device list is fixed unless a GPU is plugged or unplugged, and building it
/// takes the Metal global lock the render thread also wants.
private enum MetalDeviceCache {
    nonisolated(unsafe) private static var cached: [any MTLDevice] = []
    private static let lock = NSLock()

    static func devices(rescan: Bool) -> [any MTLDevice] {
        lock.lock()
        defer { lock.unlock() }
        if rescan || cached.isEmpty { cached = MTLCopyAllDevices() }
        return cached
    }
}
