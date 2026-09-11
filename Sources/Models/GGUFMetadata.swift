// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

struct GGUFMetadata: Sendable {
    fileprivate let strings: [String: String]
    fileprivate let integerValues: [String: UInt64]

    func string(for key: String) -> String? {
        strings[key]
    }

    func uint32(forSuffix suffix: String) -> UInt32? {
        let value = integerValues[suffix]
            ?? integerValues.first(where: { $0.key.hasSuffix(".\(suffix)") })?.value
        return value.flatMap(UInt32.init(exactly:))
    }

    /// Quantization declared by the GGUF header. This is more reliable than
    /// `general.name`, which converters often leave as the base model's BF16 name.
    var fileTypeLabel: String? {
        guard let value = integerValues["general.file_type"] else { return nil }
        return Self.fileTypeLabels[value]
    }

    var isMoE: Bool {
        if let experts = uint32(forSuffix: "expert_count") { return experts > 0 }
        guard let architecture = string(for: "general.architecture") else { return false }
        return Self.moeArchitectures.contains(architecture.lowercased())
    }

    private static let moeArchitectures: Set<String> = [
        "olmoe", "deepseek", "deepseek2", "deepseek2-ocr", "deepseek32", "deepseek4",
    ]

    private static let fileTypeLabels: [UInt64: String] = [
        0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1",
        7: "Q8_0", 8: "Q5_0", 9: "Q5_1",
        10: "Q2_K", 11: "Q3_K_S", 12: "Q3_K_M", 13: "Q3_K_L",
        14: "Q4_K_S", 15: "Q4_K_M", 16: "Q5_K_S", 17: "Q5_K_M",
        18: "Q6_K", 19: "IQ2_XXS", 20: "IQ2_XS", 21: "Q2_K_S",
        22: "IQ3_XS", 23: "IQ3_XXS", 24: "IQ1_S", 25: "IQ4_NL",
        26: "IQ3_S", 27: "IQ3_M", 28: "IQ2_S", 29: "IQ2_M",
        30: "IQ4_XS", 31: "IQ1_M", 32: "BF16",
        36: "TQ1_0", 37: "TQ2_0", 38: "MXFP4", 39: "NVFP4",
        40: "Q1_0", 41: "Q2_0",
    ]
}

struct GGUFTensorFlags: Sendable {
    let hasNextNTensor: Bool
    let hasTurboQuantTensor: Bool
    /// Metal refuses bf16 on cards without the family that provides it, weights included.
    let hasBF16Tensor: Bool
    /// Experts whose scales live in a companion tensor; the meta backend cannot split those.
    let hasExpertScaleTensor: Bool
    /// Bytes one repeating block occupies, split between its expert weights and the rest.
    /// `--n-cpu-moe` moves only the expert half, which is what unbalances a layer split.
    let expertBytesPerLayer: UInt64
    let otherBytesPerLayer: UInt64
}


/// Average bytes one element takes, by GGUF type id. Unknown types fall back to a
/// four-bit quant, the most common case in the catalogue.
private func ggufBytesPerElement(_ typeID: UInt32) -> Double {
    switch typeID {
    case 0: return 4                       // F32
    case 1, 30: return 2                   // F16, BF16
    case 2, 3: return 18.0/32              // Q4_0, Q4_1
    case 6, 7: return 22.0/32              // Q5_0, Q5_1
    case 8: return 34.0/32                 // Q8_0
    case 10: return 84.0/256               // Q2_K
    case 11: return 110.0/256              // Q3_K
    case 12: return 144.0/256              // Q4_K
    case 13: return 176.0/256              // Q5_K
    case 14: return 210.0/256              // Q6_K
    case 20: return 18.0/32                // IQ4_NL
    case 23: return 136.0/256              // IQ4_XS
    case 39: return 17.0/32                // MXFP4
    default: return 144.0/256
    }
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
    nonisolated(unsafe) private static var nextNEntries: [FileKey: Bool] = [:]

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
            return GGUFTensorFlags(hasNextNTensor: false, hasTurboQuantTensor: false, hasBF16Tensor: false,
                                   hasExpertScaleTensor: false,
                                   expertBytesPerLayer: 0, otherBytesPerLayer: 0)
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
        nextNEntries[key] = parsed.hasNextNTensor
        lock.unlock()
        return parsed
    }

    static func hasNextNTensor(at path: String) -> Bool {
        guard let key = fileKey(for: path) else { return false }
        lock.lock()
        if let cached = nextNEntries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let found = scanForNextNTensor(at: key.path)
        lock.lock()
        removeStaleEntries(for: key.path, keeping: key)
        nextNEntries[key] = found
        lock.unlock()
        return found
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
        nextNEntries = nextNEntries.filter { $0.key.path != path || $0.key == key }
    }

    private static func readPrefix(at path: String, limit: Int) -> Data? {
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size > 0 else { return nil }
        let count = min(limit, Int(status.st_size))
        let pointer = mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard pointer != MAP_FAILED, let pointer else { return nil }

        // Parsing only touches the GGUF header. A private read-only mapping avoids
        // allocating an 8/32 MB heap buffer for every model in the catalogue.
        return Data(bytesNoCopy: pointer, count: count, deallocator: .custom { memory, length in
            munmap(memory, length)
        })
    }

    private static func parseMetadata(at path: String) -> GGUFMetadata? {
        guard let data = readPrefix(at: path, limit: 32 * 1024 * 1024) else { return nil }
        return parse(from: data)
    }

    /// `data` only needs to span the header, so a range request can stand in for the file.
    static func parse(from data: Data) -> GGUFMetadata? {
        var cursor = GGUFDataCursor(data: data)
        guard cursor.readBytes(count: 4) == Data([0x47, 0x47, 0x55, 0x46]),
              let version = cursor.readUInt32(), version >= 2,
              cursor.readUInt64() != nil,
              let metadataCount = cursor.readUInt64(), metadataCount <= 1_000_000 else { return nil }

        var strings: [String: String] = [:]
        var integerValues: [String: UInt64] = [:]

        for _ in 0..<metadataCount {
            guard let key = cursor.readString(maxLength: 1 << 20),
                  let valueType = cursor.readUInt32() else { return nil }

            // llama.cpp converters commonly place general.file_type after the
            // tokenizer. Read that scalar directly without walking every token.
            if key.hasPrefix("tokenizer.") {
                if let fileType = cursor.findUInt32MetadataValue(for: "general.file_type") {
                    integerValues["general.file_type"] = UInt64(fileType)
                }
                return GGUFMetadata(strings: strings, integerValues: integerValues)
            }

            switch valueType {
            case 0:
                guard let value = cursor.readUInt8() else { return nil }
                integerValues[key] = UInt64(value)
            case 1:
                guard let value = cursor.readInt8() else { return nil }
                if value >= 0 { integerValues[key] = UInt64(value) }
            case 2:
                guard let value = cursor.readUInt16() else { return nil }
                integerValues[key] = UInt64(value)
            case 3:
                guard let value = cursor.readInt16() else { return nil }
                if value >= 0 { integerValues[key] = UInt64(value) }
            case 4:
                guard let value = cursor.readUInt32() else { return nil }
                integerValues[key] = UInt64(value)
            case 5:
                guard let value = cursor.readInt32() else { return nil }
                if value >= 0 { integerValues[key] = UInt64(value) }
            case 8:
                guard let value = cursor.readString(maxLength: 4 << 20) else { return nil }
                strings[key] = value
            case 10:
                guard let value = cursor.readUInt64() else { return nil }
                integerValues[key] = value
            case 11:
                guard let value = cursor.readInt64() else { return nil }
                if value >= 0 { integerValues[key] = UInt64(value) }
            default:
                guard cursor.skipValue(type: valueType) else { return nil }
            }
        }

        return GGUFMetadata(strings: strings, integerValues: integerValues)
    }

    /// The other files of a split GGUF, in order. The first part carries the metadata and no
    /// tensors at all, so a scan that stops there sees an empty model.
    private static func splitSiblings(of path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".gguf") else { return [] }
        let stem = String(name.dropLast(5))
        // <base>-00001-of-000NN
        let parts = stem.components(separatedBy: "-of-")
        guard parts.count == 2, let total = Int(parts[1]), total > 1,
              let dash = parts[0].lastIndex(of: "-") else { return [] }
        let base = String(parts[0][parts[0].startIndex..<dash])
        let dir = (path as NSString).deletingLastPathComponent
        return (1...total).map {
            (dir as NSString).appendingPathComponent(String(format: "%@-%05d-of-%05d.gguf", base, $0, total))
        }
    }

    private static func parseTensorFlags(at path: String) -> GGUFTensorFlags {
        let empty = GGUFTensorFlags(hasNextNTensor: false, hasTurboQuantTensor: false, hasBF16Tensor: false,
                                    hasExpertScaleTensor: false,
                                    expertBytesPerLayer: 0, otherBytesPerLayer: 0)

        let siblings = splitSiblings(of: path)
        if siblings.count > 1 {
            var merged = empty
            for part in siblings where FileManager.default.fileExists(atPath: part) {
                let flags = parseTensorFlagsOne(at: part)
                merged = GGUFTensorFlags(
                    hasNextNTensor: merged.hasNextNTensor || flags.hasNextNTensor,
                    hasTurboQuantTensor: merged.hasTurboQuantTensor || flags.hasTurboQuantTensor,
                    hasBF16Tensor: merged.hasBF16Tensor || flags.hasBF16Tensor,
                    hasExpertScaleTensor: merged.hasExpertScaleTensor || flags.hasExpertScaleTensor,
                    expertBytesPerLayer: merged.expertBytesPerLayer &+ flags.expertBytesPerLayer,
                    otherBytesPerLayer: merged.otherBytesPerLayer &+ flags.otherBytesPerLayer)
            }
            return merged
        }

        return parseTensorFlagsOne(at: path)
    }

    /// MTP detection only needs one tensor name. Searching the mapped header is
    /// much cheaper than decoding every tokenizer entry and tensor descriptor.
    private static func scanForNextNTensor(at path: String) -> Bool {
        guard let data = readPrefix(at: path, limit: 32 * 1024 * 1024) else { return false }
        let needle = Data(".nextn.".utf8)
        var searchStart = 0
        while searchStart <= data.count - needle.count,
              let match = data.range(of: needle, in: searchStart..<data.count) {
            defer { searchStart = match.upperBound }
            let earliestName = max(8, match.lowerBound - 256)
            for nameStart in earliestName...match.lowerBound {
                let lengthOffset = nameStart - 8
                let length = data.withUnsafeBytes { raw in
                    UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: lengthOffset, as: UInt64.self))
                }
                guard length > 0, length <= 1_024,
                      let byteCount = Int(exactly: length),
                      nameStart + byteCount >= match.upperBound,
                      nameStart + byteCount + 4 <= data.count else { continue }
                let nameEnd = nameStart + byteCount
                guard let name = String(data: data[nameStart..<nameEnd], encoding: .utf8),
                      name.hasPrefix("blk."), name.contains(".nextn.") else { continue }
                let dimensions = data.withUnsafeBytes { raw in
                    UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: nameEnd, as: UInt32.self))
                }
                let descriptorBytes = 4 + Int(dimensions) * 8 + 4 + 8
                if dimensions <= 8, nameEnd + descriptorBytes <= data.count { return true }
            }
        }
        return false
    }

    private static func parseTensorFlagsOne(at path: String) -> GGUFTensorFlags {
        let empty = GGUFTensorFlags(hasNextNTensor: false, hasTurboQuantTensor: false, hasBF16Tensor: false,
                                    hasExpertScaleTensor: false,
                                    expertBytesPerLayer: 0, otherBytesPerLayer: 0)
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
        var hasBF16 = false
        var hasExpertScale = false
        var expertBytes: UInt64 = 0
        var otherBytes: UInt64 = 0
        for _ in 0..<tensorCount {
            guard let name = cursor.readString(maxLength: 1 << 20),
                  let dimensions = cursor.readUInt32(), dimensions <= 8 else { return empty }
            var elements: UInt64 = 1
            for _ in 0..<Int(dimensions) {
                guard let extent = cursor.readUInt64() else { return empty }
                elements &*= max(1, extent)
            }
            guard let tensorType = cursor.readUInt32(),
                  cursor.readUInt64() != nil else { return empty }
            if name.hasPrefix("blk.0.") {
                let bytes = UInt64(Double(elements) * ggufBytesPerElement(tensorType))
                if name.contains("_exps.") { expertBytes &+= bytes } else { otherBytes &+= bytes }
            }
            hasNextN = hasNextN || name.contains(".nextn.")
            hasTurboQuant = hasTurboQuant || tensorType == 45 || tensorType == 46
            hasBF16 = hasBF16 || tensorType == 30
            if name.hasSuffix("_exps.scale") { hasExpertScale = true }
        }

        return GGUFTensorFlags(hasNextNTensor: hasNextN, hasTurboQuantTensor: hasTurboQuant,
                               hasBF16Tensor: hasBF16, hasExpertScaleTensor: hasExpertScale,
                               expertBytesPerLayer: expertBytes, otherBytesPerLayer: otherBytes)
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

    mutating func readUInt8() -> UInt8? {
        guard skipIsValid(count: 1) else { return nil }
        let value = data[offset]
        offset += 1
        return value
    }

    mutating func readInt8() -> Int8? {
        readUInt8().map { Int8(bitPattern: $0) }
    }

    mutating func readUInt16() -> UInt16? {
        guard skipIsValid(count: 2) else { return nil }
        let value = data.withUnsafeBytes { raw -> UInt16 in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        }
        offset += 2
        return UInt16(littleEndian: value)
    }

    mutating func readInt16() -> Int16? {
        readUInt16().map { Int16(bitPattern: $0) }
    }

    mutating func readUInt32() -> UInt32? {
        guard skipIsValid(count: 4) else { return nil }
        let value = data.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readInt32() -> Int32? {
        readUInt32().map { Int32(bitPattern: $0) }
    }

    mutating func readUInt64() -> UInt64? {
        guard skipIsValid(count: 8) else { return nil }
        let value = data.withUnsafeBytes { raw -> UInt64 in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
        offset += 8
        return UInt64(littleEndian: value)
    }

    mutating func readInt64() -> Int64? {
        readUInt64().map { Int64(bitPattern: $0) }
    }

    mutating func readString(maxLength: Int) -> String? {
        guard let rawLength = readUInt64(), rawLength <= UInt64(maxLength),
              let length = Int(exactly: rawLength),
              skipIsValid(count: length) else { return nil }

        // Data slices may retain the complete multi-megabyte GGUF header. Make the
        // comparatively tiny metadata string own its bytes before caching it.
        let range = offset..<(offset + length)
        let bytes = Array(data[range])
        offset += length
        return String(bytes: bytes, encoding: .utf8)
    }

    mutating func skipString(maxLength: Int) -> Bool {
        guard let rawLength = readUInt64(), rawLength <= UInt64(maxLength),
              let length = Int(exactly: rawLength) else { return false }
        return skip(count: length)
    }

    func findUInt32MetadataValue(for key: String) -> UInt32? {
        let needle = Data(key.utf8)
        var start = offset
        while start <= data.count - needle.count,
              let match = data.range(of: needle, in: start..<data.count) {
            defer { start = match.upperBound }
            guard match.lowerBound >= 8, match.upperBound + 8 <= data.count else { continue }
            let keyLength = data.withUnsafeBytes { raw in
                UInt64(littleEndian: raw.loadUnaligned(
                    fromByteOffset: match.lowerBound - 8, as: UInt64.self))
            }
            let type = data.withUnsafeBytes { raw in
                UInt32(littleEndian: raw.loadUnaligned(
                    fromByteOffset: match.upperBound, as: UInt32.self))
            }
            guard keyLength == UInt64(needle.count), type == 4 else { continue }
            return data.withUnsafeBytes { raw in
                UInt32(littleEndian: raw.loadUnaligned(
                    fromByteOffset: match.upperBound + 4, as: UInt32.self))
            }
        }
        return nil
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
            return skipString(maxLength: 64 << 20)
        case 9:
            guard let elementType = readUInt32(), elementType != 9,
                  let rawCount = readUInt64(), rawCount <= 100_000_000 else { return false }
            if elementType == 8 {
                for _ in 0..<rawCount {
                    guard skipString(maxLength: 64 << 20) else { return false }
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
