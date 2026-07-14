import Foundation

struct GGUFMetadata: Sendable {
    fileprivate let strings: [String: String]
    fileprivate let uint32Values: [String: UInt32]

    func string(for key: String) -> String? {
        strings[key]
    }

    func uint32(forSuffix suffix: String) -> UInt32? {
        uint32Values[suffix]
            ?? uint32Values.first(where: { $0.key.hasSuffix(".\(suffix)") })?.value
    }
}

struct GGUFTensorFlags: Sendable {
    let hasNextNTensor: Bool
    let hasTurboQuantTensor: Bool
}

enum GGUFMetadataCache {
    private struct FileKey: Hashable {
        let path: String
        let size: UInt64
        let modificationDate: TimeInterval
    }

    private enum MetadataEntry {
        case valid(GGUFMetadata)
        case invalid
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var metadataEntries: [FileKey: MetadataEntry] = [:]
    nonisolated(unsafe) private static var tensorEntries: [FileKey: GGUFTensorFlags] = [:]

    static func metadata(at path: String) -> GGUFMetadata? {
        guard let key = fileKey(for: path) else { return nil }

        lock.lock()
        if let entry = metadataEntries[key] {
            lock.unlock()
            if case .valid(let metadata) = entry { return metadata }
            return nil
        }
        lock.unlock()

        let parsed = parseMetadata(at: key.path)

        lock.lock()
        removeStaleEntries(for: key.path, keeping: key)
        metadataEntries[key] = parsed.map(MetadataEntry.valid) ?? .invalid
        lock.unlock()
        return parsed
    }

    static func tensorFlags(at path: String) -> GGUFTensorFlags {
        guard let key = fileKey(for: path) else {
            return GGUFTensorFlags(hasNextNTensor: false, hasTurboQuantTensor: false)
        }

        lock.lock()
        if let flags = tensorEntries[key] {
            lock.unlock()
            return flags
        }
        lock.unlock()

        let parsed = parseTensorFlags(at: key.path)

        lock.lock()
        removeStaleEntries(for: key.path, keeping: key)
        tensorEntries[key] = parsed
        lock.unlock()
        return parsed
    }

    private static func fileKey(for path: String) -> FileKey? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: standardized),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileKey(path: standardized, size: size, modificationDate: date)
    }

    private static func removeStaleEntries(for path: String, keeping key: FileKey) {
        metadataEntries = metadataEntries.filter { $0.key.path != path || $0.key == key }
        tensorEntries = tensorEntries.filter { $0.key.path != path || $0.key == key }
    }

    private static func readPrefix(at path: String, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit)
    }

    private static func parseMetadata(at path: String) -> GGUFMetadata? {
        guard let data = readPrefix(at: path, limit: 8 * 1024 * 1024) else { return nil }
        var cursor = GGUFDataCursor(data: data)
        guard cursor.readBytes(count: 4) == Data([0x47, 0x47, 0x55, 0x46]),
              let version = cursor.readUInt32(), version >= 2,
              cursor.readUInt64() != nil,
              let metadataCount = cursor.readUInt64(), metadataCount <= 1_000_000 else { return nil }

        var strings: [String: String] = [:]
        var uint32Values: [String: UInt32] = [:]

        for _ in 0..<metadataCount {
            guard let key = cursor.readString(maxLength: 1 << 20),
                  let valueType = cursor.readUInt32() else { return nil }

            // Model metadata precedes the tokenizer in llama.cpp-generated GGUF files.
            // Stop here to avoid walking hundreds of thousands of tokenizer strings.
            if key.hasPrefix("tokenizer.") {
                return GGUFMetadata(strings: strings, uint32Values: uint32Values)
            }

            switch valueType {
            case 4:
                guard let value = cursor.readUInt32() else { return nil }
                uint32Values[key] = value
            case 8:
                guard let value = cursor.readString(maxLength: 4 << 20) else { return nil }
                strings[key] = value
            default:
                guard cursor.skipValue(type: valueType) else { return nil }
            }
        }

        return GGUFMetadata(strings: strings, uint32Values: uint32Values)
    }

    private static func parseTensorFlags(at path: String) -> GGUFTensorFlags {
        let empty = GGUFTensorFlags(hasNextNTensor: false, hasTurboQuantTensor: false)
        guard let data = readPrefix(at: path, limit: 32 * 1024 * 1024) else { return empty }
        var cursor = GGUFDataCursor(data: data)
        guard cursor.readBytes(count: 4) == Data([0x47, 0x47, 0x55, 0x46]),
              let version = cursor.readUInt32(), version >= 2,
              let tensorCount = cursor.readUInt64(), tensorCount <= 10_000_000,
              let metadataCount = cursor.readUInt64(), metadataCount <= 1_000_000 else { return empty }

        for _ in 0..<metadataCount {
            guard cursor.readString(maxLength: 1 << 20) != nil,
                  let valueType = cursor.readUInt32(),
                  cursor.skipValue(type: valueType) else { return empty }
        }

        var hasNextN = false
        var hasTurboQuant = false
        for _ in 0..<tensorCount {
            guard let name = cursor.readString(maxLength: 1 << 20),
                  let dimensions = cursor.readUInt32(), dimensions <= 8 else { return empty }
            guard cursor.skip(count: Int(dimensions) * 8),
                  let tensorType = cursor.readUInt32(),
                  cursor.readUInt64() != nil else { return empty }
            hasNextN = hasNextN || name.contains(".nextn.")
            hasTurboQuant = hasTurboQuant || tensorType == 45 || tensorType == 46
        }

        return GGUFTensorFlags(hasNextNTensor: hasNextN, hasTurboQuantTensor: hasTurboQuant)
    }
}

private struct GGUFDataCursor {
    let data: Data
    var offset = 0

    mutating func readBytes(count: Int) -> Data? {
        guard skipIsValid(count: count) else { return nil }
        let range = offset..<(offset + count)
        offset += count
        return data.subdata(in: range)
    }

    mutating func readUInt32() -> UInt32? {
        guard skipIsValid(count: 4) else { return nil }
        let value = data.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readUInt64() -> UInt64? {
        guard skipIsValid(count: 8) else { return nil }
        let value = data.withUnsafeBytes { raw -> UInt64 in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
        offset += 8
        return UInt64(littleEndian: value)
    }

    mutating func readString(maxLength: Int) -> String? {
        guard let rawLength = readUInt64(), rawLength <= UInt64(maxLength),
              let length = Int(exactly: rawLength),
              let bytes = readBytes(count: length) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    mutating func skip(count: Int) -> Bool {
        guard skipIsValid(count: count) else { return false }
        offset += count
        return true
    }

    mutating func skipValue(type: UInt32) -> Bool {
        switch type {
        case 0, 1, 7:
            return skip(count: 1)
        case 2, 3:
            return skip(count: 2)
        case 4, 5, 6:
            return skip(count: 4)
        case 8:
            return readString(maxLength: 64 << 20) != nil
        case 9:
            guard let elementType = readUInt32(), elementType != 9,
                  let rawCount = readUInt64(), rawCount <= 100_000_000 else { return false }
            if elementType == 8 {
                for _ in 0..<rawCount {
                    guard readString(maxLength: 64 << 20) != nil else { return false }
                }
                return true
            }
            guard let elementSize = Self.primitiveSize(for: elementType) else { return false }
            let (byteCount, overflow) = rawCount.multipliedReportingOverflow(by: UInt64(elementSize))
            guard !overflow, let count = Int(exactly: byteCount) else { return false }
            return skip(count: count)
        case 10, 11, 12:
            return skip(count: 8)
        default:
            return false
        }
    }

    private func skipIsValid(count: Int) -> Bool {
        count >= 0 && offset <= data.count && count <= data.count - offset
    }

    private static func primitiveSize(for type: UInt32) -> Int? {
        switch type {
        case 0, 1, 7: return 1
        case 2, 3: return 2
        case 4, 5, 6: return 4
        case 10, 11, 12: return 8
        default: return nil
        }
    }
}
