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
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [Profile] = []
    private let storeKey = "profiles"

    init() { load() }

    func saveCurrent(name: String) {
        let s = ServerSettings.fromDefaults()
        let engine: String
        if s.serverBinary == ServerSettings.defaultBinary {
            engine = "bundled"
        } else if s.serverBinary == ServerSettings.turboBinary {
            engine = "turbo"
        } else {
            engine = s.serverBinary
        }
        let p = Profile(name: name, modelPath: s.modelPath, ngl: s.ngl, ncmoe: s.ncmoe,
                        ctx: s.ctx, threads: s.threads, flashAttn: s.flashAttn,
                        noMmap: s.noMmap, jinja: s.jinja, concurrencyDisable: s.concurrencyDisable,
                        vramReserve: s.vramReserveMB, gpuIndex: s.gpuIndex, extraArgs: s.extraArgs,
                        cacheTypeK: s.cacheTypeK, cacheTypeV: s.cacheTypeV, mlock: s.mlock, port: s.port,
                        specMTP: s.specMTP, engine: engine,
                        cacheRAM: s.cacheRAM, reasoningInline: s.reasoningInline,
                        parallelSlots: s.parallelSlots)
        profiles.removeAll { $0.name == name }
        profiles.append(p)
        save()
    }

    func apply(_ p: Profile) {
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
        switch p.engine {
        case "bundled": d.set(ServerSettings.defaultBinary, forKey: SettingsKeys.serverBinary)
        case "turbo": d.set(ServerSettings.turboBinary ?? ServerSettings.defaultBinary, forKey: SettingsKeys.serverBinary)
        case let .some(path) where !path.isEmpty: d.set(path, forKey: SettingsKeys.serverBinary)
        default: break
        }
    }

    func delete(_ p: Profile) {
        profiles.removeAll { $0.id == p.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([Profile].self, from: data) else { return }
        profiles = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
