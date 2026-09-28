import Foundation

/// Compact binary encoding of `AudioEvent`s for the ring buffer.
///
/// Layout:
///
///     u8  format version (1)
///     u8  event kind
///     u64 timestamp (Float64 bit pattern, seconds since 2001-01-01)
///     fields…  each: u8 tag, varint length, `length` bytes of value
///
/// Decoders skip tags they don't know, so new fields can be added without
/// breaking older readers.
public enum EventCodec {
    public static let formatVersion: UInt8 = 1

    public enum DecodingError: Error, Equatable {
        case truncated
        case unsupportedVersion(UInt8)
        case unknownKind(UInt8)
    }

    fileprivate enum Tag: UInt8 {
        case sessionID = 1
        case sessionStart = 2
        case flags = 3
        case note = 4
        case pid = 10
        case processName = 11
        case processBundleID = 12
        case executablePath = 13
        case responsiblePID = 14
        case appName = 15
        case appBundleID = 16
        case appPath = 17
        case device = 20
    }

    // MARK: Encoding

    public static func encode(_ event: AudioEvent) -> [UInt8] {
        var writer = ByteWriter(reservingCapacity: 256)
        writer.writeUInt8(formatVersion)
        writer.writeUInt8(event.kind.rawValue)
        writer.writeUInt64(event.timestamp.timeIntervalSinceReferenceDate.bitPattern)

        if event.sessionID != 0 {
            writer.writeField(.sessionID) { $0.writeUInt64(event.sessionID) }
        }
        if let start = event.sessionStart {
            writer.writeField(.sessionStart) { $0.writeUInt64(start.timeIntervalSinceReferenceDate.bitPattern) }
        }
        if !event.flags.isEmpty {
            writer.writeField(.flags) { $0.writeUInt32(event.flags.rawValue) }
        }
        writer.writeStringField(.note, event.note)

        if let process = event.process {
            writer.writeField(.pid) { $0.writeUInt32(UInt32(bitPattern: process.pid)) }
            writer.writeStringField(.processName, process.processName)
            writer.writeStringField(.processBundleID, process.processBundleID)
            writer.writeStringField(.executablePath, process.executablePath)
            if let responsiblePID = process.responsiblePID {
                writer.writeField(.responsiblePID) { $0.writeUInt32(UInt32(bitPattern: responsiblePID)) }
            }
            writer.writeStringField(.appName, process.appName)
            writer.writeStringField(.appBundleID, process.appBundleID)
            writer.writeStringField(.appPath, process.appPath)
        }

        for device in event.devices {
            writer.writeField(.device) {
                $0.writeString(device.name)
                $0.writeString(device.uid)
            }
        }
        return writer.bytes
    }

    // MARK: Decoding

    public static func decode(_ bytes: some ContiguousBytes) throws -> AudioEvent {
        try bytes.withUnsafeBytes { try decode($0) }
    }

    /// Throws `DecodingError` if the payload is not a valid event.
    public static func decode(_ buffer: UnsafeRawBufferPointer) throws -> AudioEvent {
        do {
            return try decodeFields(buffer)
        } catch is ByteReaderError {
            throw DecodingError.truncated
        }
    }

    private static func decodeFields(_ buffer: UnsafeRawBufferPointer) throws -> AudioEvent {
        var reader = ByteReader(buffer)
        let version = try reader.readUInt8()
        guard version == formatVersion else { throw DecodingError.unsupportedVersion(version) }
        let rawKind = try reader.readUInt8()
        guard let kind = AudioEventKind(rawValue: rawKind) else { throw DecodingError.unknownKind(rawKind) }
        let timestamp = Date(timeIntervalSinceReferenceDate: Double(bitPattern: try reader.readUInt64()))

        var event = AudioEvent(kind: kind, timestamp: timestamp)
        var pid: Int32?
        var processName: String?
        var processBundleID: String?
        var executablePath: String?
        var responsiblePID: Int32?
        var appName: String?
        var appBundleID: String?
        var appPath: String?

        while !reader.isAtEnd {
            let rawTag = try reader.readUInt8()
            let value = try reader.readLengthPrefixedBytes()
            guard let tag = Tag(rawValue: rawTag) else { continue } // Unknown field from a newer writer.
            var field = ByteReader(value)
            switch tag {
            case .sessionID:
                event.sessionID = try field.readUInt64()
            case .sessionStart:
                event.sessionStart = Date(timeIntervalSinceReferenceDate: Double(bitPattern: try field.readUInt64()))
            case .flags:
                event.flags = AudioEventFlags(rawValue: try field.readUInt32())
            case .note:
                event.note = string(value)
            case .pid:
                pid = Int32(bitPattern: try field.readUInt32())
            case .processName:
                processName = string(value)
            case .processBundleID:
                processBundleID = string(value)
            case .executablePath:
                executablePath = string(value)
            case .responsiblePID:
                responsiblePID = Int32(bitPattern: try field.readUInt32())
            case .appName:
                appName = string(value)
            case .appBundleID:
                appBundleID = string(value)
            case .appPath:
                appPath = string(value)
            case .device:
                let name = try field.readString()
                let uid = try field.readString()
                event.devices.append(OutputDevice(name: name, uid: uid))
            }
        }

        if pid != nil || processName != nil {
            event.process = ProcessIdentity(
                pid: pid ?? 0,
                processName: processName ?? "",
                processBundleID: processBundleID,
                executablePath: executablePath,
                responsiblePID: responsiblePID,
                appName: appName,
                appBundleID: appBundleID,
                appPath: appPath
            )
        }
        return event
    }

    private static func string(_ bytes: UnsafeRawBufferPointer) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

fileprivate extension ByteWriter {
    mutating func writeField(_ tag: EventCodec.Tag, _ body: (inout ByteWriter) -> Void) {
        var value = ByteWriter()
        body(&value)
        writeUInt8(tag.rawValue)
        writeVarint(UInt64(value.bytes.count))
        writeBytes(value.bytes)
    }

    mutating func writeStringField(_ tag: EventCodec.Tag, _ string: String?) {
        guard let string else { return }
        let utf8 = string.utf8
        writeUInt8(tag.rawValue)
        writeVarint(UInt64(utf8.count))
        writeBytes(utf8)
    }
}
