import Foundation
import Testing
@testable import WhatMadeThatSoundKit

@Suite struct RingLogTests {
    let directory: TemporaryDirectory
    let url: URL

    init() throws {
        directory = try TemporaryDirectory()
        url = directory.file("events.ringlog")
    }

    @Test func appendsAndReadsBackInOrder() throws {
        let log = try RingLog.openForWriting(url: url, capacity: 1 << 20)
        let sequences = try log.append((0 ..< 100).map(samplePayload))
        #expect(sequences == Array(1 ... 100))

        let (records, reader) = try log.readAll()
        #expect(records.map(\.sequence) == Array(1 ... 100))
        #expect(records.map { payloadIndex($0.payload) } == Array(0 ..< 100))
        #expect(records.allSatisfy { Array($0.payload) == samplePayload(payloadIndex($0.payload)!) })
        #expect(reader.isContinuation == false)
        #expect(reader.skippedBytes == 0)

        let stats = try #require(try log.stats())
        #expect(stats.recordCount == 100)
        #expect(stats.capacity == 1 << 20)
    }

    @Test func emptyLogReadsNothing() throws {
        let log = try RingLog.openForWriting(url: url, capacity: 8192)
        #expect(try log.readAll().records.isEmpty)
        #expect(try log.stats()?.recordCount == 0)
        #expect(try log.stats()?.usedBytes == 0)
    }

    @Test func evictsOldestRecordsWhenFull() throws {
        let capacity: UInt64 = 4096
        let log = try RingLog.openForWriting(url: url, capacity: capacity)
        // Append one at a time so the ring wraps at many different offsets,
        // including records that straddle the physical end of the file.
        for index in 0 ..< 2000 {
            try log.append([samplePayload(index)])
            let stats = try #require(try log.stats())
            #expect(stats.usedBytes <= capacity)
        }
        #expect(try fileSize(url) <= RingLog.headerSize + capacity)

        let records = try log.readAll().records
        let indices = records.compactMap { payloadIndex($0.payload) }
        #expect(indices.count == records.count)
        #expect(indices.last == 1999)
        // Contiguous run of the most recent records.
        #expect(indices == Array((2000 - indices.count) ..< 2000))
        // The ring should be close to full: evicting just enough, no more.
        let stats = try #require(try log.stats())
        #expect(stats.usedBytes > capacity - UInt64(RingLog.recordSize(forPayloadCount: 80)))
        #expect(stats.recordCount == UInt64(records.count))
        #expect(records.allSatisfy { Array($0.payload) == samplePayload(payloadIndex($0.payload)!) })
    }

    @Test func largeBatchesEvictCorrectly() throws {
        let log = try RingLog.openForWriting(url: url, capacity: 4096)
        // A batch bigger than the whole ring keeps only what fits of its newest records.
        let sequences = try log.append((0 ..< 500).map(samplePayload))
        #expect(sequences.count == 500)
        let indices = try log.readAll().records.compactMap { payloadIndex($0.payload) }
        #expect(indices.last == 499)
        #expect(indices == Array((500 - indices.count) ..< 500))
    }

    @Test func incrementalReadsReturnOnlyNewRecords() throws {
        let log = try RingLog.openForWriting(url: url, capacity: 1 << 16)
        try log.append((0 ..< 10).map(samplePayload))
        let first = try log.readAll()
        #expect(first.records.count == 10)

        let nothing = try log.readAll(from: first.reader.position)
        #expect(nothing.records.isEmpty)
        #expect(nothing.reader.isContinuation)

        try log.append((10 ..< 15).map(samplePayload))
        let second = try log.readAll(from: nothing.reader.position)
        #expect(second.reader.isContinuation)
        #expect(second.records.compactMap { payloadIndex($0.payload) } == Array(10 ..< 15))
    }

    @Test func separateHandlesSeeEachOthersWrites() throws {
        let writer = try RingLog.openForWriting(url: url, capacity: 1 << 16)
        let reader = try #require(try RingLog.openForReading(url: url))
        try writer.append([samplePayload(1)])
        let first = try reader.readAll()
        #expect(first.records.count == 1)
        try writer.append([samplePayload(2)])
        let second = try reader.readAll(from: first.reader.position)
        #expect(second.records.compactMap { payloadIndex($0.payload) } == [2])
    }

    @Test func positionPastEvictedDataRestartsFromOldest() throws {
        let log = try RingLog.openForWriting(url: url, capacity: 4096)
        try log.append([samplePayload(0)])
        let position = try log.readAll().reader.position
        for index in 1 ..< 500 {
            try log.append([samplePayload(index)])
        }
        let result = try log.readAll(from: position)
        #expect(result.reader.isContinuation == false)
        #expect(result.records.compactMap { payloadIndex($0.payload) }.last == 499)
    }

    @Test func clearRemovesEverythingAndInvalidatesPositions() throws {
        let log = try RingLog.openForWriting(url: url, capacity: 1 << 16)
        try log.append((0 ..< 50).map(samplePayload))
        let position = try log.readAll().reader.position
        let fileIDBefore = try #require(try log.stats()).fileID

        try log.clear()
        #expect(try log.readAll().records.isEmpty)
        #expect(try fileSize(url) == RingLog.headerSize)
        #expect(try log.stats()?.fileID != fileIDBefore)

        try log.append([samplePayload(99)])
        let result = try log.readAll(from: position)
        #expect(result.reader.isContinuation == false)
        #expect(result.records.compactMap { payloadIndex($0.payload) } == [99])
        // Sequence numbers keep increasing across a clear.
        #expect(result.records.first?.sequence == 51)
    }

    @Test func reopeningContinuesTheLog() throws {
        do {
            let log = try RingLog.openForWriting(url: url, capacity: 4096)
            for index in 0 ..< 300 {
                try log.append([samplePayload(index)])
            }
        }
        let reopened = try RingLog.openForWriting(url: url, capacity: 999_999) // Existing capacity wins.
        #expect(try reopened.stats()?.capacity == 4096)
        let sequences = try reopened.append([samplePayload(300)])
        #expect(sequences == [301])
        let indices = try reopened.readAll().records.compactMap { payloadIndex($0.payload) }
        #expect(indices.last == 300)
        #expect(indices == Array((301 - indices.count) ..< 301))
    }

    @Test func recoversFromTornWriteAtTheEnd() throws {
        let log = try RingLog.openForWriting(url: url, capacity: 1 << 16)
        try log.append((0 ..< 20).map(samplePayload))
        let records = try log.readAll().records
        let last = try #require(records.last)
        // Simulate the header reaching disk but the last record's bytes not.
        try overwrite(url, at: RingLog.headerSize + last.offset + 30, with: [0xFF, 0xFF, 0xFF, 0xFF])

        let reader = try #require(try RingLog.openForReading(url: url))
        let seen = try reader.readAll()
        #expect(seen.records.count == 19)
        #expect(seen.reader.skippedBytes > 0)

        let recovered = try RingLog.openForWriting(url: url, capacity: 1 << 16)
        #expect(try recovered.stats()?.recordCount == 19)
        let sequences = try recovered.append([samplePayload(100)])
        #expect(sequences == [21]) // Never reuses a sequence number.
        let indices = try recovered.readAll().records.compactMap { payloadIndex($0.payload) }
        #expect(indices == Array(0 ..< 19) + [100])
    }

    @Test func readerSkipsCorruptRecordInTheMiddle() throws {
        let log = try RingLog.openForWriting(url: url, capacity: 1 << 16)
        try log.append((0 ..< 10).map(samplePayload))
        let records = try log.readAll().records
        try overwrite(url, at: RingLog.headerSize + records[4].offset + 26, with: [0x00, 0x01, 0x02])

        let indices = try log.readAll().records.compactMap { payloadIndex($0.payload) }
        #expect(indices == [0, 1, 2, 3, 5, 6, 7, 8, 9])

        // Appending (and evicting across the damage) keeps working.
        let small = try RingLog.openForWriting(url: url, capacity: 1 << 16)
        try small.append([samplePayload(10)])
        #expect(try small.readAll().records.compactMap { payloadIndex($0.payload) }.last == 10)
    }

    @Test func survivesDamagedHeaderSlot() throws {
        let log = try RingLog.openForWriting(url: url, capacity: 1 << 16)
        try log.append((0 ..< 5).map(samplePayload))
        try log.append((5 ..< 7).map(samplePayload))
        // Destroy whichever slot holds the newest header; the previous one must be used.
        for slotOffset in RingLog.headerSlotOffsets {
            let reopened = try RingLog.openForWriting(url: url, capacity: 1 << 16)
            let before = try reopened.readAll().records.count
            try overwrite(url, at: UInt64(slotOffset) + 40, with: [0xAB])
            let after = try reopened.readAll().records.count
            #expect(after <= before)
            #expect(after >= 5)
            // Restore a valid header by appending (writes the other slot).
            try reopened.append([samplePayload(100 + Int(slotOffset))])
        }
    }

    @Test func movesAsideFilesThatAreNotLogs() throws {
        try Data("definitely not a ring log".utf8).write(to: url)
        let log = try RingLog.openForWriting(url: url, capacity: 8192)
        try log.append([samplePayload(1)])
        #expect(try log.readAll().records.count == 1)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(siblings.contains { $0.hasPrefix("events.ringlog.corrupt-") })
    }

    @Test func missingFileOpensAsNilForReading() throws {
        #expect(try RingLog.openForReading(url: url) == nil)
    }

    @Test func rejectsOversizedPayloadsAndTinyCapacities() throws {
        #expect(throws: RingLog.Error.capacityTooSmall(100)) {
            try RingLog.openForWriting(url: url, capacity: 100)
        }
        let log = try RingLog.openForWriting(url: url, capacity: 1 << 20)
        let big = [UInt8](repeating: 1, count: RingLog.maxPayloadSize + 1)
        #expect(throws: RingLog.Error.payloadTooLarge(big.count)) { try log.append([big]) }
        let readOnly = try #require(try RingLog.openForReading(url: url))
        #expect(throws: RingLog.Error.readOnly) { try readOnly.append([samplePayload(1)]) }
    }

    @Test func concurrentWriterAndReaderStayConsistent() async throws {
        let writer = try RingLog.openForWriting(url: url, capacity: 16 * 1024)
        let url = self.url
        let total = 3000

        async let written: Void = Task.detached {
            for index in 0 ..< total {
                try writer.append([samplePayload(index)])
            }
        }.value

        let reader = try #require(try RingLog.openForReading(url: url))
        var position: RingLog.Position?
        var lastIndex = -1
        var lastSequence: UInt64 = 0
        var sawEnd = false
        while !sawEnd {
            let result = try reader.readAll(from: position)
            for record in result.records {
                let index = try #require(payloadIndex(record.payload))
                #expect(Array(record.payload) == samplePayload(index))
                #expect(index > lastIndex)
                #expect(record.sequence > lastSequence || !result.reader.isContinuation)
                lastIndex = index
                lastSequence = record.sequence
                if index == total - 1 { sawEnd = true }
            }
            position = result.reader.position
            await Task.yield()
        }
        try await written
    }
}
