import Foundation

/// Appends little-endian binary values to a byte array.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(reservingCapacity capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    mutating func writeUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func writeUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func writeUInt64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    /// Unsigned LEB128.
    mutating func writeVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    mutating func writeBytes(_ other: some Collection<UInt8>) {
        bytes.append(contentsOf: other)
    }

    /// Writes a length-prefixed UTF-8 string.
    mutating func writeString(_ string: String) {
        let utf8 = string.utf8
        writeVarint(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func writeZeros(_ count: Int) {
        bytes.append(contentsOf: repeatElement(0, count: count))
    }

    /// Overwrites four bytes previously written at `offset`.
    mutating func patchUInt32(_ value: UInt32, at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { source in
            for index in 0 ..< 4 {
                bytes[offset + index] = source[index]
            }
        }
    }
}

enum ByteReaderError: Error, Equatable {
    case truncated
    case malformedVarint
}

/// Reads little-endian binary values from a buffer, with bounds checking.
struct ByteReader {
    private let buffer: UnsafeRawBufferPointer
    private(set) var offset = 0

    init(_ buffer: UnsafeRawBufferPointer) {
        self.buffer = buffer
    }

    var remaining: Int { buffer.count - offset }
    var isAtEnd: Bool { offset >= buffer.count }

    mutating func readUInt8() throws(ByteReaderError) -> UInt8 {
        guard remaining >= 1 else { throw .truncated }
        defer { offset += 1 }
        return buffer[offset]
    }

    mutating func readUInt32() throws(ByteReaderError) -> UInt32 {
        guard remaining >= 4 else { throw .truncated }
        defer { offset += 4 }
        return UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    mutating func readUInt64() throws(ByteReaderError) -> UInt64 {
        guard remaining >= 8 else { throw .truncated }
        defer { offset += 8 }
        return UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    mutating func readVarint() throws(ByteReaderError) -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try readUInt8()
            guard shift < 64 else { throw .malformedVarint }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func readBytes(_ count: Int) throws(ByteReaderError) -> UnsafeRawBufferPointer {
        guard count >= 0, remaining >= count else { throw .truncated }
        defer { offset += count }
        return UnsafeRawBufferPointer(rebasing: buffer[offset ..< offset + count])
    }

    /// Reads a varint length followed by that many bytes.
    mutating func readLengthPrefixedBytes() throws(ByteReaderError) -> UnsafeRawBufferPointer {
        let length = try readVarint()
        guard length <= UInt64(remaining) else { throw .truncated }
        return try readBytes(Int(length))
    }

    mutating func readString() throws(ByteReaderError) -> String {
        String(decoding: try readLengthPrefixedBytes(), as: UTF8.self)
    }
}
