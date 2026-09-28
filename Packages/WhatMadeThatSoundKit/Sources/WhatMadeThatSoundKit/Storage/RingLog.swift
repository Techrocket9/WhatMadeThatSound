import Darwin
import Foundation
import zlib

/// A fixed-capacity ring buffer of variable-length records, stored in one file.
///
/// Once `capacity` bytes of records have been written, each append evicts the
/// oldest records to make room, so the file never grows beyond
/// `headerSize + capacity` bytes and always holds the most recent history.
///
/// ## File layout
///
///     [0, 4096)             header region: two 128-byte header slots at 0 and 512
///     [4096, 4096+capacity) data region, used circularly
///
/// Positions inside the data region are *logical* 64-bit offsets that only ever
/// grow; the physical location is `headerSize + logical % capacity`. The live
/// records occupy the logical range `[tail, head)`.
///
/// Each header write goes to the slot not holding the current header, together
/// with a bumped generation number and a CRC, so a torn header write can never
/// destroy the last good header.
///
/// Each record is 8-byte aligned:
///
///     u32 magic   u32 length (whole record incl. padding)
///     u64 sequence number
///     u32 crc32   u32 payload length
///     payload, zero padding
///
/// ## Concurrency
///
/// Any number of processes may open the same file. Every operation takes a
/// `flock(2)` lock for the brief moment it touches the file: exclusive for
/// appends, shared for reads. Readers stream large ranges chunk by chunk,
/// re-validating against the header for each chunk, so they never block the
/// writer for long.
///
/// Appends first commit any tail advance (eviction) to the header, then write the
/// record bytes, then commit the new head — with write barriers in between — so
/// that the records between tail and head are intact after a crash.
public final class RingLog: @unchecked Sendable {
    // MARK: Format constants

    static let headerSize: UInt64 = 4096
    static let headerSlotSize = 128
    static let headerSlotOffsets: [off_t] = [0, 512]
    static let headerMagic: UInt64 = 0x474E_4952_5354_4D57 // "WMTSRING" little-endian
    static let formatVersion: UInt32 = 1
    static let recordMagic: UInt32 = 0x4345_5257 // "WREC" little-endian
    static let recordHeaderSize = 24
    /// Largest payload accepted; keeps a corrupt length field from causing huge reads.
    public static let maxPayloadSize = 64 * 1024
    static let maxRecordSize = recordHeaderSize + maxPayloadSize + 8
    public static let minimumCapacity: UInt64 = 4096
    static let readChunkSize = 4 * 1024 * 1024

    // MARK: Public types

    /// Where a reader stopped; pass it back to continue reading new records only.
    public struct Position: Hashable, Sendable {
        public var fileID: UUID
        public var offset: UInt64
    }

    public struct Record: Sendable {
        public var sequence: UInt64
        /// Logical offset of the record.
        public var offset: UInt64
        public var payload: ArraySlice<UInt8>
    }

    public struct Stats: Sendable, Equatable {
        public var fileID: UUID
        public var capacity: UInt64
        /// Bytes currently occupied by live records.
        public var usedBytes: UInt64
        /// Size of the file on disk (header + data region written so far).
        public var fileSize: UInt64
        /// Number of live records.
        public var recordCount: UInt64
        public var createdAt: Date
    }

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case posix(operation: String, code: Int32)
        case unrecognizedFile
        case payloadTooLarge(Int)
        case capacityTooSmall(UInt64)
        case readOnly

        public var description: String {
            switch self {
            case let .posix(operation, code):
                "\(operation) failed: \(String(cString: strerror(code))) (\(code))"
            case .unrecognizedFile:
                "The file is not a What Made That Sound event log"
            case let .payloadTooLarge(size):
                "Record payload of \(size) bytes exceeds the \(RingLog.maxPayloadSize)-byte limit"
            case let .capacityTooSmall(capacity):
                "Capacity \(capacity) is smaller than the minimum of \(RingLog.minimumCapacity) bytes"
            case .readOnly:
                "The log was opened read-only"
            }
        }
    }

    // MARK: State

    public let url: URL
    private let fd: Int32
    private let isWritable: Bool
    private let threadLock = NSLock()

    deinit {
        close(fd)
    }

    private init(url: URL, fd: Int32, isWritable: Bool) {
        self.url = url
        self.fd = fd
        self.isWritable = isWritable
    }

    // MARK: Opening

    /// Opens the log for appending, creating it with `capacity` bytes of data
    /// region if needed. An existing log keeps the capacity it was created with.
    ///
    /// If the file exists but is not a valid log, it is moved aside (renamed with
    /// a `.corrupt-<timestamp>` suffix) and a fresh log is created.
    public static func openForWriting(url: URL, capacity: UInt64) throws -> RingLog {
        guard capacity >= minimumCapacity else { throw Error.capacityTooSmall(capacity) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var log = try open(url: url, flags: O_RDWR | O_CREAT)
        let movedAside = try log.withLock(LOCK_EX) { () throws -> Bool in
            if try log.fileSize() == 0 {
                try log.initializeHeader(capacity: capacity)
                return false
            }
            guard var header = try log.readHeader() else { return true }
            try log.recover(&header)
            return false
        }
        if movedAside {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".corrupt-\(stamp)")
            try FileManager.default.moveItem(at: url, to: aside)
            log = try open(url: url, flags: O_RDWR | O_CREAT)
            try log.withLock(LOCK_EX) {
                if try log.fileSize() == 0 {
                    try log.initializeHeader(capacity: capacity)
                }
            }
        }
        return log
    }

    /// Opens an existing log for reading. Returns `nil` if the file doesn't exist.
    public static func openForReading(url: URL) throws -> RingLog? {
        do {
            return try open(url: url, flags: O_RDONLY)
        } catch Error.posix(_, ENOENT) {
            return nil
        }
    }

    /// Opens an existing log for maintenance such as `clear()`, without creating it
    /// or running crash recovery (the agent does that). `nil` if it doesn't exist.
    public static func openExisting(url: URL) throws -> RingLog? {
        do {
            return try open(url: url, flags: O_RDWR)
        } catch Error.posix(_, ENOENT) {
            return nil
        }
    }

    private static func open(url: URL, flags: Int32) throws -> RingLog {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            Darwin.open(path!, flags | O_CLOEXEC, 0o644)
        }
        guard fd >= 0 else { throw Error.posix(operation: "open", code: errno) }
        return RingLog(url: url, fd: fd, isWritable: flags & O_ACCMODE != O_RDONLY)
    }

    // MARK: Writing

    /// Appends records atomically with respect to readers, evicting the oldest
    /// records as needed. Returns the sequence numbers assigned to the payloads.
    @discardableResult
    public func append(_ payloads: [[UInt8]]) throws -> [UInt64] {
        guard isWritable else { throw Error.readOnly }
        guard !payloads.isEmpty else { return [] }
        for payload in payloads where payload.count > Self.maxPayloadSize {
            throw Error.payloadTooLarge(payload.count)
        }

        return try withLock(LOCK_EX) {
            guard var header = try readHeader() else { throw Error.unrecognizedFile }

            // Encode as many records as fit in the ring at once; loop for huge batches.
            var sequences: [UInt64] = []
            var index = 0
            while index < payloads.count {
                var blob = ByteWriter(reservingCapacity: 4096)
                var batchSequences: [UInt64] = []
                while index < payloads.count {
                    let recordSize = Self.recordSize(forPayloadCount: payloads[index].count)
                    if !blob.bytes.isEmpty, UInt64(blob.bytes.count + recordSize) > header.capacity { break }
                    guard UInt64(recordSize) <= header.capacity else { throw Error.payloadTooLarge(payloads[index].count) }
                    let sequence = header.nextSequence
                    header.nextSequence += 1
                    Self.encodeRecord(payload: payloads[index], sequence: sequence, into: &blob)
                    batchSequences.append(sequence)
                    index += 1
                }
                let length = UInt64(blob.bytes.count)

                // 1. Evict from the tail until the new records fit, and commit that first
                //    so no reader or crash-recovery ever trusts bytes we're about to overwrite.
                let oldTail = header.tail
                while header.head + length - header.tail > header.capacity {
                    let evicted = try nextRecordStart(after: header.tail, header: header)
                    header.tail = evicted.next
                    if evicted.removedRecord, header.recordCount > 0 { header.recordCount -= 1 }
                }
                if header.tail != oldTail {
                    try writeHeader(&header)
                    barrier()
                }

                // 2. Write the records, then 3. publish them by advancing the head.
                try writeLogical(blob.bytes, at: header.head, header: header)
                barrier()
                header.head += length
                header.recordCount += UInt64(batchSequences.count)
                try writeHeader(&header)
                sequences += batchSequences
            }
            return sequences
        }
    }

    /// Removes every record. Readers holding a `Position` will start over.
    public func clear() throws {
        guard isWritable else { throw Error.readOnly }
        try withLock(LOCK_EX) {
            guard var header = try readHeader() else { throw Error.unrecognizedFile }
            header.fileID = UUID()
            header.head = 0
            header.tail = 0
            header.recordCount = 0
            try writeHeader(&header)
            barrier()
            guard ftruncate(fd, off_t(Self.headerSize)) == 0 else {
                throw Error.posix(operation: "ftruncate", code: errno)
            }
        }
    }

    // MARK: Reading

    /// Summary of the log without reading any records.
    public func stats() throws -> Stats? {
        try withLock(LOCK_SH) {
            guard let header = try readHeader() else { return nil }
            return Stats(
                fileID: header.fileID,
                capacity: header.capacity,
                usedBytes: header.head - header.tail,
                fileSize: try fileSize(),
                recordCount: header.recordCount,
                createdAt: header.createdAt
            )
        }
    }

    /// Creates a reader that streams records starting at `position`, or at the
    /// oldest record if `position` is `nil` or no longer valid (the log was
    /// cleared, recreated, or has since overwritten that point).
    public func makeReader(from position: Position?) throws -> Reader {
        try withLock(LOCK_SH) {
            guard let header = try readHeader() else { throw Error.unrecognizedFile }
            if let position, position.fileID == header.fileID,
               position.offset >= header.tail, position.offset <= header.head {
                return Reader(log: self, fileID: header.fileID, offset: position.offset,
                              isContinuation: true, takesLocks: true)
            }
            return Reader(log: self, fileID: header.fileID, offset: header.tail,
                          isContinuation: false, takesLocks: true)
        }
    }

    /// Streams records in order, reading the file in large chunks.
    ///
    /// The lock is held only while a chunk is copied, never while the caller
    /// processes records. Not thread-safe; use from one task at a time.
    public final class Reader {
        private let log: RingLog
        private let fileID: UUID
        private let takesLocks: Bool
        private var offset: UInt64
        private var chunk: [UInt8] = []
        private var chunkStart: UInt64 = 0
        private var chunkEndsAtHead = false
        private var cursor = 0
        private var lastSequence: UInt64?
        private var finished = false

        /// `true` if reading continues from the position that was passed in;
        /// `false` if it starts from the oldest record.
        public let isContinuation: Bool
        /// Bytes skipped because they were evicted while reading, or corrupt.
        public private(set) var skippedBytes: UInt64 = 0

        init(log: RingLog, fileID: UUID, offset: UInt64, isContinuation: Bool, takesLocks: Bool) {
            self.log = log
            self.fileID = fileID
            self.offset = offset
            self.isContinuation = isContinuation
            self.takesLocks = takesLocks
        }

        /// Where to resume reading after the last record returned.
        public var position: Position { Position(fileID: fileID, offset: offset) }

        /// The next record, or `nil` at the end of the log.
        public func next() throws -> Record? {
            while !finished {
                if let record = parseNextInChunk() { return record }
                try loadChunk()
            }
            return nil
        }

        private func parseNextInChunk() -> Record? {
            while cursor < chunk.count {
                let recordOffset = chunkStart + UInt64(cursor)
                let result = chunk.withUnsafeBytes { buffer in
                    RingLog.validateRecord(in: buffer, at: cursor, previousSequence: lastSequence)
                }
                switch result {
                case let .valid(sequence, length, payloadRange):
                    let record = Record(sequence: sequence, offset: recordOffset, payload: chunk[payloadRange])
                    cursor += length
                    offset = recordOffset + UInt64(length)
                    lastSequence = sequence
                    return record
                case .incomplete where !chunkEndsAtHead:
                    return nil // The rest of the record is in the next chunk.
                case .incomplete, .invalid:
                    // Damaged bytes: resynchronise on the next aligned position.
                    let step = min(8, chunk.count - cursor)
                    cursor += step
                    offset = recordOffset + UInt64(step)
                    skippedBytes += UInt64(step)
                }
            }
            return nil
        }

        private func loadChunk() throws {
            if takesLocks {
                try log.withLock(LOCK_SH) { try loadChunkLocked() }
            } else {
                try loadChunkLocked()
            }
        }

        private func loadChunkLocked() throws {
            guard let header = try log.readHeader(), header.fileID == fileID else {
                finished = true // The log was cleared or replaced underneath us.
                return
            }
            if offset < header.tail {
                // The writer evicted records we hadn't read yet.
                skippedBytes += header.tail - offset
                offset = header.tail
            }
            guard header.head > offset else {
                finished = true
                return
            }
            let available = header.head - offset
            let count = Int(min(available, UInt64(RingLog.readChunkSize)))
            chunk = try log.readLogical(count: count, at: offset, header: header)
            chunkStart = offset
            chunkEndsAtHead = UInt64(count) == available
            cursor = 0
        }
    }

    // MARK: Record encoding & validation

    static func recordSize(forPayloadCount count: Int) -> Int {
        (recordHeaderSize + count + 7) & ~7
    }

    static func encodeRecord(payload: [UInt8], sequence: UInt64, into writer: inout ByteWriter) {
        let start = writer.bytes.count
        let length = recordSize(forPayloadCount: payload.count)
        writer.writeUInt32(recordMagic)
        writer.writeUInt32(UInt32(length))
        writer.writeUInt64(sequence)
        writer.writeUInt32(0) // CRC placeholder
        writer.writeUInt32(UInt32(payload.count))
        writer.writeBytes(payload)
        writer.writeZeros(length - recordHeaderSize - payload.count)
        let crc = writer.bytes.withUnsafeBytes { buffer in
            recordChecksum(UnsafeRawBufferPointer(rebasing: buffer[start ..< start + recordHeaderSize + payload.count]))
        }
        writer.patchUInt32(crc, at: start + 16)
    }

    /// CRC over the record header (minus the CRC field itself) and the payload.
    static func recordChecksum(_ record: UnsafeRawBufferPointer) -> UInt32 {
        var crc = zlib.crc32(0, nil, 0)
        crc = zlib.crc32(crc, record.baseAddress, 16)
        crc = zlib.crc32(crc, record.baseAddress! + 20, uInt(record.count - 20))
        return UInt32(truncatingIfNeeded: crc)
    }

    enum Validation: Equatable {
        case valid(sequence: UInt64, length: Int, payload: Range<Int>)
        case incomplete
        case invalid
    }

    static func validateRecord(in buffer: UnsafeRawBufferPointer, at offset: Int, previousSequence: UInt64?) -> Validation {
        guard buffer.count - offset >= recordHeaderSize else { return .incomplete }
        func u32(_ at: Int) -> UInt32 { UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + at, as: UInt32.self)) }
        guard u32(0) == recordMagic else { return .invalid }
        let length = Int(u32(4))
        let payloadCount = Int(u32(20))
        guard length % 8 == 0, length <= maxRecordSize, payloadCount <= maxPayloadSize,
              length == recordSize(forPayloadCount: payloadCount)
        else { return .invalid }
        guard buffer.count - offset >= length else { return .incomplete }
        let sequence = UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self))
        if let previousSequence, sequence <= previousSequence { return .invalid }
        let checked = UnsafeRawBufferPointer(rebasing: buffer[offset ..< offset + recordHeaderSize + payloadCount])
        guard recordChecksum(checked) == u32(16) else { return .invalid }
        let payloadStart = offset + recordHeaderSize
        return .valid(sequence: sequence, length: length, payload: payloadStart ..< payloadStart + payloadCount)
    }

    // MARK: Header

    struct Header: Equatable {
        var generation: UInt64
        var capacity: UInt64
        var head: UInt64
        var tail: UInt64
        var nextSequence: UInt64
        var fileID: UUID
        var createdAt: Date
        var recordCount: UInt64

        func encoded() -> [UInt8] {
            var writer = ByteWriter(reservingCapacity: RingLog.headerSlotSize)
            writer.writeUInt64(RingLog.headerMagic)
            writer.writeUInt32(RingLog.formatVersion)
            writer.writeUInt32(UInt32(RingLog.headerSize))
            writer.writeUInt64(generation)
            writer.writeUInt64(capacity)
            writer.writeUInt64(head)
            writer.writeUInt64(tail)
            writer.writeUInt64(nextSequence)
            withUnsafeBytes(of: fileID.uuid) { writer.writeBytes($0) }
            writer.writeUInt64(createdAt.timeIntervalSinceReferenceDate.bitPattern)
            writer.writeUInt64(recordCount)
            writer.writeZeros(RingLog.headerSlotSize - 4 - writer.bytes.count)
            let crc = writer.bytes.withUnsafeBytes { UInt32(truncatingIfNeeded: zlib.crc32(0, $0.baseAddress, uInt($0.count))) }
            writer.writeUInt32(crc)
            return writer.bytes
        }

        static func decode(_ bytes: [UInt8]) -> Header? {
            guard bytes.count == RingLog.headerSlotSize else { return nil }
            return bytes.withUnsafeBytes { buffer -> Header? in
                let body = UnsafeRawBufferPointer(rebasing: buffer[0 ..< RingLog.headerSlotSize - 4])
                let storedCRC = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: RingLog.headerSlotSize - 4, as: UInt32.self))
                guard UInt32(truncatingIfNeeded: zlib.crc32(0, body.baseAddress, uInt(body.count))) == storedCRC else { return nil }
                var reader = ByteReader(buffer)
                do {
                    guard try reader.readUInt64() == RingLog.headerMagic,
                          try reader.readUInt32() == RingLog.formatVersion,
                          try reader.readUInt32() == UInt32(RingLog.headerSize)
                    else { return nil }
                    let generation = try reader.readUInt64()
                    let capacity = try reader.readUInt64()
                    let head = try reader.readUInt64()
                    let tail = try reader.readUInt64()
                    let nextSequence = try reader.readUInt64()
                    let uuidBytes = try reader.readBytes(16)
                    let fileID = UUID(uuid: uuidBytes.loadUnaligned(as: uuid_t.self))
                    let createdAt = Date(timeIntervalSinceReferenceDate: Double(bitPattern: try reader.readUInt64()))
                    let recordCount = try reader.readUInt64()
                    guard capacity >= RingLog.minimumCapacity, tail <= head, head - tail <= capacity else { return nil }
                    return Header(generation: generation, capacity: capacity, head: head, tail: tail,
                                  nextSequence: nextSequence, fileID: fileID, createdAt: createdAt,
                                  recordCount: recordCount)
                } catch {
                    return nil
                }
            }
        }
    }

    private func initializeHeader(capacity: UInt64) throws {
        var header = Header(generation: 0, capacity: capacity, head: 0, tail: 0, nextSequence: 1,
                            fileID: UUID(), createdAt: Date(), recordCount: 0)
        try writeHeader(&header)
        barrier()
    }

    /// The valid header slot with the highest generation, or `nil` if neither is valid.
    func readHeader() throws -> Header? {
        var best: Header?
        for slotOffset in Self.headerSlotOffsets {
            var bytes = [UInt8](repeating: 0, count: Self.headerSlotSize)
            let count = try bytes.withUnsafeMutableBytes { try preadFully($0, at: slotOffset) }
            guard count == Self.headerSlotSize, let header = Header.decode(bytes) else { continue }
            if header.generation >= (best?.generation ?? 0) { best = header }
        }
        return best
    }

    private func writeHeader(_ header: inout Header) throws {
        header.generation += 1
        let slot = Self.headerSlotOffsets[Int(header.generation % 2)]
        let bytes = header.encoded()
        try bytes.withUnsafeBytes { try pwriteFully($0, at: slot) }
    }

    // MARK: Recovery

    /// After an unclean shutdown, makes `tail` point at the first intact record and
    /// `head` at the end of the last one, so appends continue after good data.
    /// Must be called with the exclusive lock held.
    private func recover(_ header: inout Header) throws {
        guard header.head > header.tail else { return }
        let original = header

        let reader = Reader(log: self, fileID: header.fileID, offset: header.tail,
                            isContinuation: false, takesLocks: false)
        var firstStart: UInt64?
        var end = header.tail
        var lastSequence: UInt64?
        var count: UInt64 = 0
        while let record = try reader.next() {
            count += 1
            if firstStart == nil { firstStart = record.offset }
            end = record.offset + UInt64(Self.recordSize(forPayloadCount: record.payload.count))
            lastSequence = record.sequence
        }
        header.tail = firstStart ?? header.tail
        header.head = end
        header.recordCount = count
        if let lastSequence, header.nextSequence <= lastSequence {
            header.nextSequence = lastSequence + 1
        }
        if header != original {
            try writeHeader(&header)
            barrier()
        }
    }

    /// Returns the logical offset of the first intact record after the record at
    /// `offset` (or after `offset` itself if no intact record starts there), or
    /// `head` if there is none; and whether an intact record started at `offset`.
    private func nextRecordStart(after offset: UInt64, header: Header) throws -> (next: UInt64, removedRecord: Bool) {
        var candidate: UInt64
        let removedRecord: Bool
        if let record = try readRecordHeader(at: offset, header: header) {
            candidate = offset + UInt64(record.length)
            removedRecord = true
        } else {
            candidate = offset + 8
            removedRecord = false
        }
        while candidate < header.head {
            if try readRecordHeader(at: candidate, header: header) != nil { return (candidate, removedRecord) }
            candidate += 8
        }
        return (header.head, removedRecord)
    }

    /// Reads and fully validates the record at a logical offset.
    private func readRecordHeader(at offset: UInt64, header: Header) throws -> (sequence: UInt64, length: Int)? {
        let available = header.head - offset
        guard available >= UInt64(Self.recordHeaderSize) else { return nil }
        let prefix = try readLogical(count: Self.recordHeaderSize, at: offset, header: header)
        let length = prefix.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))) }
        guard length >= Self.recordHeaderSize, length <= Self.maxRecordSize, UInt64(length) <= available else { return nil }
        let bytes = try readLogical(count: length, at: offset, header: header)
        let validation = bytes.withUnsafeBytes { Self.validateRecord(in: $0, at: 0, previousSequence: nil) }
        guard case let .valid(sequence, validLength, _) = validation else { return nil }
        return (sequence, validLength)
    }

    // MARK: Low-level I/O

    private func physicalOffset(_ logical: UInt64, header: Header) -> UInt64 {
        Self.headerSize + logical % header.capacity
    }

    func readLogical(count: Int, at logical: UInt64, header: Header) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        try result.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                let position = logical + UInt64(done)
                let physical = physicalOffset(position, header: header)
                let untilWrap = Int(header.capacity - position % header.capacity)
                let length = min(count - done, untilWrap)
                let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[done ..< done + length])
                let read = try preadFully(slice, at: off_t(physical))
                guard read == length else { throw Error.posix(operation: "read", code: EIO) }
                done += length
            }
        }
        return result
    }

    private func writeLogical(_ bytes: [UInt8], at logical: UInt64, header: Header) throws {
        try bytes.withUnsafeBytes { buffer in
            var done = 0
            while done < buffer.count {
                let position = logical + UInt64(done)
                let physical = physicalOffset(position, header: header)
                let untilWrap = Int(header.capacity - position % header.capacity)
                let length = min(buffer.count - done, untilWrap)
                try pwriteFully(UnsafeRawBufferPointer(rebasing: buffer[done ..< done + length]), at: off_t(physical))
                done += length
            }
        }
    }

    /// Reads until `buffer` is full or EOF; returns the number of bytes read.
    private func preadFully(_ buffer: UnsafeMutableRawBufferPointer, at offset: off_t) throws -> Int {
        var done = 0
        while done < buffer.count {
            let result = pread(fd, buffer.baseAddress! + done, buffer.count - done, offset + off_t(done))
            if result < 0 {
                if errno == EINTR { continue }
                throw Error.posix(operation: "pread", code: errno)
            }
            if result == 0 { break }
            done += result
        }
        return done
    }

    private func pwriteFully(_ buffer: UnsafeRawBufferPointer, at offset: off_t) throws {
        var done = 0
        while done < buffer.count {
            let result = pwrite(fd, buffer.baseAddress! + done, buffer.count - done, offset + off_t(done))
            if result < 0 {
                if errno == EINTR { continue }
                throw Error.posix(operation: "pwrite", code: errno)
            }
            done += result
        }
    }

    private func fileSize() throws -> UInt64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Error.posix(operation: "fstat", code: errno) }
        return UInt64(info.st_size)
    }

    /// Orders preceding writes before subsequent ones on stable storage (APFS),
    /// without the cost of a full flush.
    private func barrier() {
        if fcntl(fd, F_BARRIERFSYNC) != 0 {
            fsync(fd)
        }
    }

    /// Serialises use of this instance across threads (`flock` only excludes other
    /// open file descriptions) and across processes.
    private func withLock<T>(_ operation: Int32, _ body: () throws -> T) throws -> T {
        threadLock.lock()
        defer { threadLock.unlock() }
        while flock(fd, operation) != 0 {
            if errno == EINTR { continue }
            throw Error.posix(operation: "flock", code: errno)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
