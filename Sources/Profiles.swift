import Foundation

/// Profile: a named snapshot of the entire server configuration.
struct Profile: Codable, Identifiable {
    var id = UUID()
    var name: String
    var modelPath: String
    var ngl: Int
    var ncmoe: Int
    var ctx: Int
    var threads: Int
    var flashAttn: String
    var noMmap: Bool
    var jinja: Bool
    var concurrencyDisable: Bool
    var vramReserve: Int
    var gpuIndex: Int
    var extraArgs: String
    var cacheTypeK: String
    var cacheTypeV: String
    var mlock: Bool
    var port: Int
    var specMTP: Bool? = nil
    // "bundled" | "turbo" | absolute path. Optional for backward compatibility.
    var engine: String?
    // Optionals for backward compatibility with profiles saved by older builds.
    var cacheRAM: Int? = nil
    var reasoningInline: Bool? = nil
    var parallelSlots: Int? = nil
    var faAmd: Bool? = nil
    var persistCache: Bool? = nil
    var multiGPU: Bool? = nil
    var forcePrivateBuffers: Bool? = nil
    var cacheReuse: Bool? = nil
    var loadVision: Bool? = nil
    var localNetworkDiscovery: Bool? = nil
    var gpuList: [Int]? = nil
    var embeddings: Bool? = nil
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [Profile] = []
    /// Name of the profile last applied, shown in the picker so the selection is
    /// visible. nil means "no profile" (the user's own settings).
    @Published var activeProfileName: String? = UserDefaults.standard.string(forKey: activeKey)
    /// The user's configuration captured the moment they applied the first profile,
    /// so "Default" can return to exactly what they had before any profile.
    @Published var baselineConfig: Profile?
    private let storeKey = "profiles"
    private static let activeKey = "activeProfileName"
    private static let baselineKey = "baselineProfile"

    init() { load() }

    func saveCurrent(name: String) {
        add(ServerSettings.fromDefaults().makeProfile(name: name))
    }

    /// Stores a profile (e.g. snapshotted from a benchmark run). Replaces any
    /// existing profile with the same name and gives it a fresh id.
    func add(_ profile: Profile) {
        var p = profile
        p.id = UUID()
        profiles.removeAll { $0.name == p.name }
        profiles.append(p)
        save()
    }

    func apply(_ p: Profile) {
        // First time we leave the "no profile" state, snapshot the user's config so
        // "Default" can restore exactly what they had before any profile.
        if activeProfileName == nil, baselineConfig == nil {
            let base = ServerSettings.fromDefaults().makeProfile(name: "__baseline__")
            baselineConfig = base
            if let data = try? JSONEncoder().encode(base) {
                UserDefaults.standard.set(data, forKey: Self.baselineKey)
            }
        }
        write(p)
        activeProfileName = p.name
        UserDefaults.standard.set(p.name, forKey: Self.activeKey)
    }

    /// Restore the configuration the user had before applying any profile and clear
    /// the selection. If no baseline was captured, just clears the selection.
    func clearActive() {
        if let base = baselineConfig { write(base) }
        activeProfileName = nil
        baselineConfig = nil
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.activeKey)
        d.removeObject(forKey: Self.baselineKey)
    }

    /// Make a config the new global default — used by the benchmark's "Apply to
    /// global". Unlike `apply`, this is not a named-profile overlay: it updates the
    /// settings you return to with "Default", and leaves no profile selected.
    func setAsDefault(_ p: Profile) {
        write(p)
        activeProfileName = nil
        baselineConfig = nil
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.activeKey)
        d.removeObject(forKey: Self.baselineKey)
    }

    /// Writes a profile's values into the live settings (no selection bookkeeping).
    private func write(_ p: Profile) {
        let d = UserDefaults.standard
        d.set(p.modelPath, forKey: SettingsKeys.modelPath)
        d.set(p.ngl, forKey: SettingsKeys.ngl)
        d.set(p.ncmoe, forKey: SettingsKeys.ncmoe)
        d.set(p.ctx, forKey: SettingsKeys.ctx)
        d.set(p.threads, forKey: SettingsKeys.threads)
        d.set(p.flashAttn, forKey: SettingsKeys.flashAttn)
        d.set(p.noMmap, forKey: SettingsKeys.noMmap)
        d.set(p.jinja, forKey: SettingsKeys.jinja)
        d.set(p.concurrencyDisable, forKey: SettingsKeys.concurrencyDisable)
        d.set(p.vramReserve, forKey: SettingsKeys.vramReserve)
        d.set(p.gpuIndex, forKey: SettingsKeys.gpuIndex)
        d.set(p.extraArgs, forKey: SettingsKeys.extraArgs)
        d.set(p.cacheTypeK, forKey: SettingsKeys.cacheTypeK)
        d.set(p.cacheTypeV, forKey: SettingsKeys.cacheTypeV)
        d.set(p.mlock, forKey: SettingsKeys.mlock)
        d.set(p.port, forKey: SettingsKeys.port)
        if let mtp = p.specMTP { d.set(mtp, forKey: SettingsKeys.specMTP) }
        if let cram = p.cacheRAM { d.set(cram, forKey: SettingsKeys.cacheRAM) }
        if let inline = p.reasoningInline { d.set(inline, forKey: SettingsKeys.reasoningInline) }
        if let slots = p.parallelSlots { d.set(slots, forKey: SettingsKeys.parallelSlots) }
        if let v = p.faAmd { d.set(v, forKey: SettingsKeys.faAmd) }
        if let v = p.persistCache { d.set(v, forKey: SettingsKeys.persistCache) }
        if let v = p.multiGPU { d.set(v, forKey: SettingsKeys.multiGPU) }
        if let v = p.forcePrivateBuffers { d.set(v, forKey: SettingsKeys.forcePrivateBuffers) }
        if let v = p.cacheReuse { d.set(v, forKey: SettingsKeys.cacheReuse) }
        if let v = p.gpuList { d.set(v.map(String.init).joined(separator: ","), forKey: SettingsKeys.gpuList) }
        if let v = p.embeddings { d.set(v, forKey: SettingsKeys.embeddings) }
        switch p.engine {
        case "bundled": d.set(ServerSettings.defaultBinary, forKey: SettingsKeys.serverBinary)
        case "turbo": d.set(ServerSettings.turboBinary ?? ServerSettings.defaultBinary, forKey: SettingsKeys.serverBinary)
        case let .some(path) where !path.isEmpty: d.set(path, forKey: SettingsKeys.serverBinary)
        default: break
        }
    }

    func delete(_ p: Profile) {
        profiles.removeAll { $0.id == p.id }
        if activeProfileName == p.name {
            activeProfileName = nil
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
        }
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.baselineKey),
           let base = try? JSONDecoder().decode(Profile.self, from: data) {
            baselineConfig = base
        }
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([Profile].self, from: data) else { return }
        profiles = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}

extension ServerSettings {
    /// "bundled" | "turbo" | absolute path, matching Profile.engine. Uses isTurbo
    /// so the bundled bin-turbo path is recognized, not shown as a raw path.
    var engineTag: String {
        if ServerSettings.isTurbo(serverBinary) { return "turbo" }
        if serverBinary == ServerSettings.defaultBinary { return "bundled" }
        return serverBinary
    }

    /// Snapshot the full runtime config into a named profile.
    func makeProfile(name: String) -> Profile {
        Profile(name: name, modelPath: modelPath, ngl: ngl, ncmoe: ncmoe, ctx: ctx,
                threads: threads, flashAttn: flashAttn, noMmap: noMmap, jinja: jinja,
                concurrencyDisable: concurrencyDisable, vramReserve: vramReserveMB,
                gpuIndex: gpuIndex, extraArgs: extraArgs, cacheTypeK: cacheTypeK,
                cacheTypeV: cacheTypeV, mlock: mlock, port: port, specMTP: specMTP,
                engine: engineTag, cacheRAM: cacheRAM, reasoningInline: reasoningInline,
                parallelSlots: parallelSlots, faAmd: faAmd, persistCache: persistCache,
                multiGPU: multiGPU, forcePrivateBuffers: forcePrivateBuffers,
                cacheReuse: cacheReuse, loadVision: loadVision,
                localNetworkDiscovery: localNetworkDiscovery,
                gpuList: gpuList, embeddings: embeddings)
    }

    /// Load a profile's config into this struct without touching UserDefaults,
    /// so the benchmark can seed a local run-config from a profile.
    mutating func apply(_ p: Profile) {
        modelPath = p.modelPath; ngl = p.ngl; ncmoe = p.ncmoe; ctx = p.ctx
        threads = p.threads; flashAttn = p.flashAttn; noMmap = p.noMmap; jinja = p.jinja
        concurrencyDisable = p.concurrencyDisable; vramReserveMB = p.vramReserve
        gpuIndex = p.gpuIndex; extraArgs = p.extraArgs; cacheTypeK = p.cacheTypeK
        cacheTypeV = p.cacheTypeV; mlock = p.mlock; port = p.port
        if let v = p.specMTP { specMTP = v }
        if let v = p.cacheRAM { cacheRAM = v }
        if let v = p.reasoningInline { reasoningInline = v }
        if let v = p.parallelSlots { parallelSlots = v }
        if let v = p.faAmd { faAmd = v }
        if let v = p.persistCache { persistCache = v }
        if let v = p.multiGPU { multiGPU = v }
        if let v = p.forcePrivateBuffers { forcePrivateBuffers = v }
        if let v = p.cacheReuse { cacheReuse = v }
        if let v = p.loadVision { loadVision = v }
        if let v = p.localNetworkDiscovery { localNetworkDiscovery = v }
        gpuList = p.gpuList ?? []
        if let v = p.embeddings { embeddings = v }
        switch p.engine {
        case "bundled": serverBinary = ServerSettings.defaultBinary
        case "turbo": serverBinary = ServerSettings.turboBinary ?? ServerSettings.defaultBinary
        case let .some(path) where !path.isEmpty: serverBinary = path
        default: break
        }
    }
}
