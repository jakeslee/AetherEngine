import Foundation
import Synchronization
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Merges independently demuxed muxed files into one packet timeline. The first demuxer is the
/// owner `Demuxer`; later demuxers are probed on the demux queue. Packets retain their
/// stream indices and codec payloads, while PTS/DTS are shifted by the elapsed duration of the
/// preceding segments. This is deliberately packet-level: no AVFoundation composition or temporary
/// remux is involved.
final class SequencePacketSource: @unchecked Sendable {
    private struct SegmentState {
        let url: URL
        var demuxer: Demuxer?
        var duration: Double?
        var timelineStart: Double
        var timestampOrigin: Double?
    }

    private weak var owner: Demuxer?
    private let headers: [String: String]
    private let profile: DemuxerOpenProfile
    private var segments: [SegmentState]
    private var currentIndex = 0
    private let closed = Atomic<Bool>(false)
    private let accessLock = NSRecursiveLock()
    // Cancellation cannot wait behind a blocked read. This registry has its own short lock,
    // never held during IO, and deliberately excludes the owner to avoid recursive cancellation.
    private let children = Mutex<[Demuxer]>([])

    init(owner: Demuxer, sequence: MediaSequence, headers: [String: String], profile: DemuxerOpenProfile) {
        self.owner = owner
        self.headers = headers
        self.profile = profile
        var cursor = 0.0
        self.segments = sequence.segments.map { item in
            let state = SegmentState(
                url: item.url,
                demuxer: nil,
                duration: item.duration,
                timelineStart: cursor,
                timestampOrigin: nil
            )
            if let duration = item.duration, duration.isFinite, duration > 0 {
                cursor += duration
            }
            return state
        }
        // Segment 0 lives only through the weak owner reference, avoiding a retain cycle.
    }

    /// Resolve every segment's duration before the engine publishes the probe. A sequence's
    /// duration is part of its load contract, and an omitted declaration must not leave the host
    /// seeing zero until playback happens to reach a later segment. The demuxers remain open for
    /// packet reads, so this costs probing rather than a second network/open pass.
    func prepare() throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let owner else { throw SequencePacketSourceError.invalidIndex }
        resolveDuration(0, from: owner.duration)
        for index in segments.indices.dropFirst() {
            let demuxer = try openDemuxer(at: index)
            resolveDuration(index, from: demuxer.duration)
        }
    }

    var duration: Double {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard !segments.isEmpty else { return 0 }
        var total = 0.0
        for state in segments {
            guard let duration = state.duration, duration.isFinite, duration > 0 else { return 0 }
            total += duration
        }
        return total
    }

    func readPacket(isCurrent: @Sendable () -> Bool) throws -> UnsafeMutablePointer<AVPacket>? {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard !closed.load(ordering: .acquiring) else { return nil }
        while currentIndex < segments.count {
            guard isCurrent(), !closed.load(ordering: .acquiring) else { throw CancellationError() }
            if currentIndex == 0 {
                guard let owner else { return nil }
                if let packet = try owner.readPacketForSequence(isCurrent: isCurrent) {
                    return shift(packet, in: 0, owner: owner)
                }
                resolveDuration(0, from: owner.duration)
            } else {
                let demuxer = try openDemuxer(at: currentIndex)
                if let packet = try demuxer.readPacket(isCurrent: isCurrent) {
                    return shift(packet, in: currentIndex, owner: owner)
                }
                resolveDuration(currentIndex, from: demuxer.duration)
            }
            currentIndex += 1
            // A previously visited child may be at EOF or an old seek target. Every sequential
            // boundary starts at that segment's own origin, including after a backward seek.
            if currentIndex < segments.count {
                let next = try openDemuxer(at: currentIndex)
                guard next.seekForSequence(to: Self.timestampOrigin(of: next)) else {
                    throw SequencePacketSourceError.seekFailed
                }
            }
        }
        return nil
    }

    func seek(to seconds: Double, streamIndex: Int32 = -1, timeout: TimeInterval = 8) -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard seconds.isFinite, seconds >= 0, !segments.isEmpty,
              !closed.load(ordering: .acquiring) else { return false }
        let index = index(containing: seconds)
        let local = max(0, seconds - segments[index].timelineStart)
        currentIndex = index
        do {
            let demuxer = try openDemuxer(at: index)
            return demuxer.seekForSequence(to: local + Self.timestampOrigin(of: demuxer),
                                           streamIndex: streamIndex, timeout: timeout)
        } catch {
            EngineLog.emit("[SequencePacketSource] seek failed at \(seconds)s: \(error)", category: .demux)
            return false
        }
    }

    func markClosed() {
        closed.store(true, ordering: .releasing)
        let snapshot = children.withLock { $0 }
        for demuxer in snapshot { demuxer.markClosed() }
    }

    func close() {
        markClosed()
        accessLock.lock()
        defer { accessLock.unlock() }
        // Never close the owner here; Demuxer.close() owns its AVFormatContext and invokes us before it.
        let retained = children.withLock { value in
            let snapshot = value
            value.removeAll()
            return snapshot
        }
        for demuxer in retained { demuxer.close() }
        for index in segments.indices { segments[index].demuxer = nil }
    }

    private func openDemuxer(at index: Int) throws -> Demuxer {
        guard index >= 0, index < segments.count else { throw SequencePacketSourceError.invalidIndex }
        guard !closed.load(ordering: .acquiring) else { throw CancellationError() }
        if index == 0, let owner { return owner }
        if let existing = segments[index].demuxer { return existing }
        let demuxer = Demuxer()
        children.withLock { $0.append(demuxer) }
        try demuxer.open(url: segments[index].url, extraHeaders: headers, profile: profile)
        guard !closed.load(ordering: .acquiring) else {
            demuxer.close()
            throw CancellationError()
        }
        guard compatible(with: demuxer) else {
            demuxer.close()
            throw SequencePacketSourceError.streamLayoutMismatch
        }
        segments[index].demuxer = demuxer
        resolveDuration(index, from: demuxer.duration)
        return demuxer
    }

    private func compatible(with demuxer: Demuxer) -> Bool {
        guard let owner else { return false }
        guard demuxer.streamCount == owner.streamCount,
              demuxer.videoStreamIndex == owner.videoStreamIndex,
              demuxer.audioStreamIndex == owner.audioStreamIndex else { return false }
        for index in 0..<max(0, Int(owner.streamCount)) {
            guard let lhs = owner.stream(at: Int32(index))?.pointee.codecpar,
                  let rhs = demuxer.stream(at: Int32(index))?.pointee.codecpar,
                  lhs.pointee.codec_type == rhs.pointee.codec_type,
                  lhs.pointee.codec_id == rhs.pointee.codec_id else { return false }
        }
        return true
    }

    private func resolveDuration(_ index: Int, from measured: Double) {
        guard index >= 0, index < segments.count else { return }
        if !(segments[index].duration ?? 0 > 0), measured.isFinite, measured > 0 {
            segments[index].duration = measured
            rebuildTimeline()
        }
    }

    private func rebuildTimeline() {
        var cursor = 0.0
        for index in segments.indices {
            segments[index].timelineStart = cursor
            if let duration = segments[index].duration, duration.isFinite, duration > 0 { cursor += duration }
        }
    }

    private func index(containing seconds: Double) -> Int {
        var selected = 0
        for index in segments.indices where segments[index].timelineStart <= seconds {
            selected = index
        }
        return selected
    }

    private func shift(_ packet: UnsafeMutablePointer<AVPacket>, in index: Int, owner: Demuxer?) -> UnsafeMutablePointer<AVPacket> {
        guard index >= 0, index < segments.count else { return packet }
        let state = segments[index]
        let origin: Double = {
            if let value = state.timestampOrigin { return value }
            let demuxer = state.demuxer ?? owner
            let value = demuxer.map(Self.timestampOrigin(of:)) ?? 0
            segments[index].timestampOrigin = value
            return value
        }()
        let delta = state.timelineStart - origin
        guard let demuxer = state.demuxer ?? owner,
              let stream = demuxer.stream(at: packet.pointee.stream_index),
              let outputStream = owner?.stream(at: packet.pointee.stream_index) else { return packet }
        let tb = stream.pointee.time_base
        guard tb.num > 0, tb.den > 0 else { return packet }
        let ticks = Int64((delta * Double(tb.den) / Double(tb.num)).rounded())
        if packet.pointee.pts != Int64.min { packet.pointee.pts = packet.pointee.pts &+ ticks }
        if packet.pointee.dts != Int64.min { packet.pointee.dts = packet.pointee.dts &+ ticks }
        // The decoder keeps the first segment's stream metadata for the whole session.
        // A different container timescale must therefore be rescaled, including packet duration.
        av_packet_rescale_ts(packet, tb, outputStream.pointee.time_base)
        packet.pointee.pos = -1
        return packet
    }

    private static func timestampOrigin(of demuxer: Demuxer) -> Double {
        var values: [Double] = []
        for index in 0..<max(0, Int(demuxer.streamCount)) {
            guard let stream = demuxer.stream(at: Int32(index)) else { continue }
            let start = stream.pointee.start_time
            let tb = stream.pointee.time_base
            guard start != Int64.min, tb.num > 0, tb.den > 0 else { continue }
            values.append(Double(start) * Double(tb.num) / Double(tb.den))
        }
        return values.min() ?? 0
    }
}

enum SequencePacketSourceError: Error, CustomStringConvertible {
    case invalidIndex
    case streamLayoutMismatch
    case seekFailed

    var description: String {
        switch self {
        case .invalidIndex: "sequence segment index out of range"
        case .streamLayoutMismatch: "sequence segments have incompatible stream layouts"
        case .seekFailed: "sequence segment could not be rewound"
        }
    }
}
