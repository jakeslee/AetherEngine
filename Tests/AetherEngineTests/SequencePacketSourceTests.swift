import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

@Suite("Packet-level media sequences")
struct SequencePacketSourceTests {
    private func temporarySegments() throws -> (URL, URL) {
        guard let data = Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                              options: .ignoreUnknownCharacters) else {
            throw TestError.invalidFixture
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-sequence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("first.mp4")
        let second = directory.appendingPathComponent("second.mp4")
        try data.write(to: first)
        try data.write(to: second)
        return (first, second)
    }

    @Test("joins independent demuxers and shifts the second segment timeline")
    func joinsPackets() throws {
        let (first, second) = try temporarySegments()
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        let source = MediaSequence(segments: [
            .init(url: first, duration: 0.1),
            .init(url: second, duration: 0.1),
        ])
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(sequence: source)
        #expect(abs(demuxer.duration - 0.2) < 0.001)

        let videoIndex = demuxer.videoStreamIndex
        var timestamps: [Int64] = []
        while let packet = try demuxer.readPacket() {
            if packet.pointee.stream_index == videoIndex, packet.pointee.pts != Int64.min {
                timestamps.append(packet.pointee.pts)
            }
            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }
        #expect(timestamps.count >= 2)
        let stream = try #require(demuxer.stream(at: videoIndex))
        let tb = stream.pointee.time_base
        let expectedShift = Int64((0.1 * Double(tb.den) / Double(tb.num)).rounded())
        #expect(timestamps.max()! - timestamps.min()! >= expectedShift)
        #expect(timestamps.count.isMultiple(of: 2))
        let half = timestamps.count / 2
        #expect(Array(timestamps.suffix(half)) == timestamps.prefix(half).map { $0 + expectedShift })
    }

    @Test("seeks through the joined elapsed timeline")
    func seeksJoinedTimeline() throws {
        let (first, second) = try temporarySegments()
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(sequence: MediaSequence(segments: [
            .init(url: first, duration: 0.1),
            .init(url: second, duration: 0.1),
        ]))
        #expect(demuxer.seekBounded(to: 0.12, anchorStreamIndex: demuxer.videoStreamIndex, timeout: 1))
        let packet = try #require(try demuxer.readPacket())
        defer { av_packet_unref(packet); av_packet_free_safe(packet) }
        let stream = try #require(demuxer.stream(at: packet.pointee.stream_index))
        let pts = Double(packet.pointee.pts) * Double(stream.pointee.time_base.num)
            / Double(stream.pointee.time_base.den)
        #expect(pts >= 0.1 && pts <= 0.12)
    }

    @Test("backward seek resets later segment cursors and preserves packet order")
    func repeatedTraversal() throws {
        let (first, second) = try temporarySegments()
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(sequence: .init(segments: [.init(url: first), .init(url: second)]))
        #expect(demuxer.duration > 0)
        func drain() throws -> [String] {
            var result: [String] = []
            while let packet = try demuxer.readPacket() {
                result.append("\(packet.pointee.stream_index):\(packet.pointee.pts):\(packet.pointee.dts)")
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            }
            return result
        }
        let original = try drain()
        #expect(original.count >= 6)
        for _ in 0..<3 {
            #expect(demuxer.seekBounded(to: 0, timeout: 1))
            #expect(try drain() == original)
        }
    }

    @Test("cancellation is idempotent and closes every segment without retaining the owner")
    func cancellationAndRelease() throws {
        let (first, second) = try temporarySegments()
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        weak var released: Demuxer?
        do {
            let demuxer = Demuxer()
            released = demuxer
            try demuxer.open(sequence: .init(segments: [.init(url: first), .init(url: second)]))
            demuxer.markClosed()
            demuxer.markClosed()
            #expect(try demuxer.readPacket() == nil)
            demuxer.close()
            demuxer.close()
        }
        #expect(released == nil)
        do {
            let demuxer = Demuxer()
            released = demuxer
            try demuxer.open(sequence: .init(segments: [.init(url: first), .init(url: second)]))
            // No explicit close: ARC must be able to enter Demuxer.deinit.
        }
        #expect(released == nil)
    }

    private enum TestError: Error { case invalidFixture }
}
