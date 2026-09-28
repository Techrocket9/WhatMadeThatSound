import Foundation
@testable import WhatMadeThatSoundKit

/// A temporary directory that is deleted when the value is released.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "WhatMadeThatSoundKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appending(path: name, directoryHint: .notDirectory)
    }
}

/// Deterministic payload whose content identifies it and whose length varies.
func samplePayload(_ index: Int) -> [UInt8] {
    Array("record-\(index)|".utf8) + [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: index % 57)
}

func payloadIndex(_ payload: some Collection<UInt8>) -> Int? {
    let text = String(decoding: payload.prefix(while: { $0 != UInt8(ascii: "|") }), as: UTF8.self)
    guard text.hasPrefix("record-") else { return nil }
    return Int(text.dropFirst("record-".count))
}

extension RingLog {
    /// Reads every record from `position` (or the beginning) to the end.
    func readAll(from position: Position? = nil) throws -> (records: [Record], reader: Reader) {
        let reader = try makeReader(from: position)
        var records: [Record] = []
        while let record = try reader.next() {
            records.append(record)
        }
        return (records, reader)
    }
}

func fileSize(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
}

/// Overwrites bytes of a file at an absolute offset.
func overwrite(_ url: URL, at offset: UInt64, with bytes: [UInt8]) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    try handle.write(contentsOf: Data(bytes))
}
