import Foundation
import Synchronization
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Joins two independently demuxed renditions — one video-only, one audio-only — into a single
/// packet timeline. The owner `Demuxer` holds the video rendition and supplies the session's
/// primary metadata; the audio rendition is opened as a child on the same demux queue.
///
/// This is packet-level by construction: the two byte streams are never concatenated, never
/// remuxed into a temporary container, and never handed to a second player. Each side keeps its
/// own `AVStream` (and therefore its own time base and codec parameters), and the merged stream
/// table presents exactly two streams to the rest of the engine: index 0 video, index 1 audio.
///
/// Timestamps are shifted by one **shared** session origin rather than per-rendition first-packet
/// times, so a real offset between the two renditions survives into playback instead of being
/// flattened to zero on both sides.
final class SeparatedPacketSource: @unchecked Sendable {
    /// The merged stream indices the engine sees. Packets are re-indexed onto these as they leave.
    static let videoIndex: Int32 = 0
    static let audioIndex: Int32 = 1

    private struct Side {
        let isVideo: Bool
        /// This rendition's origins in preferred order: the one it opened with, then its
        /// alternates. A rendition is only ever replaced from its own list.
        var urls: [URL]
        var urlIndex = 0
        /// nil means the video side is still reading from the owner demuxer. Once a rendition has
        /// been replaced it owns a child demuxer, including the video side, so either rendition can
        /// change origin without disturbing the other.
        var demuxer: Demuxer?
        var streamIndex: Int32 = -1
        var pending: UnsafeMutablePointer<AVPacket>?
        var finished = false
        /// Start time of this rendition's stream, in seconds, or nil when the container
        /// declares none.
        var origin: Double?
        var replacements = 0

        var mediaType: AVMediaType { isVideo ? AVMEDIA_TYPE_VIDEO : AVMEDIA_TYPE_AUDIO }
        var hasAlternate: Bool { urlIndex + 1 < urls.count }
    }

    private weak var owner: Demuxer?
    private let headers: [String: String]
    private let profile: DemuxerOpenProfile
    private let declaredDuration: Double?

    private var video: Side
    private var audio: Side
    /// Subtracted from both renditions. Their difference — the real A/V offset — is preserved.
    private var sessionOrigin = 0.0
    /// Where playback had reached when the last packet left, so a replacement rendition can be
    /// re-anchored to the same instant instead of restarting the programme.
    private var lastEmittedSeconds = 0.0

    private let closed = Atomic<Bool>(false)
    private let accessLock = NSRecursiveLock()
    // Cancellation must not queue behind a blocked network read, so children are reachable
    // through their own short lock that is never held across IO.
    private let children = Mutex<[Demuxer]>([])

    init(owner: Demuxer, media: SeparatedMedia, headers: [String: String], profile: DemuxerOpenProfile) {
        self.owner = owner
        self.headers = headers
        self.profile = profile
        self.declaredDuration = media.duration
        self.video = Side(isVideo: true, urls: [media.videoURL] + media.videoFallbackURLs)
        self.audio = Side(isVideo: false, urls: [media.audioURL] + media.audioFallbackURLs)
    }

    /// Open the audio rendition and fix the session's shared origin. Called once, before the
    /// engine publishes its probe: both renditions must be readable for the load to be honest
    /// about having audio, and a video-only fallback here would be exactly the silent playback
    /// this source exists to prevent.
    func prepare() throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let owner else { throw SeparatedPacketSourceError.unavailable }

        video.streamIndex = owner.firstStreamIndex(ofType: AVMEDIA_TYPE_VIDEO)
        guard video.streamIndex >= 0 else { throw SeparatedPacketSourceError.videoStreamMissing }

        // The audio rendition may fall back at open time too: an origin that is already down
        // should cost a candidate, not the session.
        var openFailure: Error?
        var opened: (demuxer: Demuxer, index: Int32)?
        while opened == nil {
            let url = audio.urls[audio.urlIndex]
            let demuxer = Demuxer()
            children.withLock { $0.append(demuxer) }
            do {
                try demuxer.open(url: url, extraHeaders: headers, profile: profile, isLive: false)
                guard !closed.load(ordering: .acquiring) else {
                    demuxer.close()
                    throw CancellationError()
                }
                let index = demuxer.firstStreamIndex(ofType: AVMEDIA_TYPE_AUDIO)
                if index >= 0 {
                    opened = (demuxer, index)
                } else {
                    openFailure = SeparatedPacketSourceError.audioStreamMissing
                    retire(demuxer)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                openFailure = error
                retire(demuxer)
            }
            if opened == nil {
                guard audio.hasAlternate else {
                    throw SeparatedPacketSourceError.audioUnreadable(
                        openFailure ?? SeparatedPacketSourceError.audioStreamMissing)
                }
                audio.urlIndex += 1
            }
        }
        guard let opened else { throw SeparatedPacketSourceError.audioStreamMissing }
        audio.demuxer = opened.demuxer
        audio.streamIndex = opened.index
        let demuxer = opened.demuxer
        let audioIndex = opened.index
        video.origin = Self.startSeconds(of: owner, streamIndex: video.streamIndex)
        audio.origin = Self.startSeconds(of: demuxer, streamIndex: audioIndex)
        sessionOrigin = min(video.origin ?? 0, audio.origin ?? 0)
    }

    var duration: Double {
        accessLock.lock()
        defer { accessLock.unlock() }
        if let declaredDuration, declaredDuration.isFinite, declaredDuration > 0 { return declaredDuration }
        // The renditions describe the same programme; a rendition that stops early would
        // otherwise advertise a timeline the other side keeps playing past.
        let videoDuration = activeDemuxer(video)?.containerDuration ?? 0
        let audioDuration = activeDemuxer(audio)?.containerDuration ?? 0
        let candidates = [videoDuration, audioDuration].filter { $0.isFinite && $0 > 0 }
        return candidates.max() ?? 0
    }

    /// The merged table: video from the owner, audio from the child. Both entries are the
    /// renditions' real `AVStream`s, so codec parameters and time bases stay authentic.
    var streamCount: Int32 { audio.demuxer == nil ? 1 : 2 }

    func stream(at index: Int32) -> UnsafeMutablePointer<AVStream>? {
        accessLock.lock()
        defer { accessLock.unlock() }
        switch index {
        case Self.videoIndex: return activeDemuxer(video)?.rawStream(at: video.streamIndex)
        case Self.audioIndex: return activeDemuxer(audio)?.rawStream(at: audio.streamIndex)
        default: return nil
        }
    }

    func isVideoStream(_ index: Int32) -> Bool { index == Self.videoIndex }

    func readPacket(isCurrent: @Sendable () -> Bool) throws -> UnsafeMutablePointer<AVPacket>? {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard !closed.load(ordering: .acquiring) else { return nil }
        guard isCurrent() else { throw CancellationError() }

        try fill(&video, isCurrent: isCurrent)
        try fill(&audio, isCurrent: isCurrent)

        // Schedule on decode order across a common seconds axis. Each side keeps its own
        // decode order internally, so B-frame DTS/PTS relationships are never reordered here.
        let videoDTS = video.pending.map { scheduleSeconds(of: $0, in: video) }
        let audioDTS = audio.pending.map { scheduleSeconds(of: $0, in: audio) }
        let takeVideo: Bool
        switch (videoDTS, audioDTS) {
        case (nil, nil): return nil
        case (_, nil): takeVideo = true
        case (nil, _): takeVideo = false
        case let (lhs?, rhs?): takeVideo = lhs <= rhs
        }
        return takeVideo ? take(&video) : take(&audio)
    }

    /// Both renditions land inside one operation. A partial landing would leave the session
    /// playing one rendition from the target and the other from wherever it happened to be,
    /// so a failure on either side fails the seek rather than half-applying it.
    func seek(to seconds: Double, streamIndex: Int32 = -1, timeout: TimeInterval = 8) -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard seconds.isFinite, seconds >= 0, !closed.load(ordering: .acquiring),
              let videoDemuxer = activeDemuxer(video),
              let audioDemuxer = activeDemuxer(audio) else { return false }
        let target = seconds + sessionOrigin
        discardPending()
        // Video lands on the random-access point at or before the target; audio lands at or
        // before the same instant. Frames between that point and the target are decoded as
        // references and dropped before presentation by the renderer's existing seek gate.
        let videoLanded = videoDemuxer.seekForSequence(to: max(0, target - (video.origin.map { $0 - sessionOrigin } ?? 0)),
                                                       streamIndex: video.streamIndex, timeout: timeout)
        let audioLanded = audioDemuxer.seekForSequence(to: max(0, target - (audio.origin.map { $0 - sessionOrigin } ?? 0)),
                                                       streamIndex: audio.streamIndex, timeout: timeout)
        guard videoLanded, audioLanded else {
            EngineLog.emit("[SeparatedPacketSource] joint seek to \(seconds)s failed "
                           + "(video=\(videoLanded) audio=\(audioLanded))", category: .demux)
            return false
        }
        video.finished = false
        audio.finished = false
        lastEmittedSeconds = seconds
        return true
    }

    func markClosed() {
        closed.store(true, ordering: .releasing)
        for demuxer in children.withLock({ $0 }) { demuxer.markClosed() }
    }

    func close() {
        markClosed()
        accessLock.lock()
        defer { accessLock.unlock() }
        discardPending()
        // Never close the owner: Demuxer.close() owns its AVFormatContext and calls us first.
        let retained = children.withLock { value -> [Demuxer] in
            let snapshot = value
            value.removeAll()
            return snapshot
        }
        for demuxer in retained { demuxer.close() }
        audio.demuxer = nil
        video.demuxer = nil
    }

    var diagnostic: String {
        accessLock.lock()
        defer { accessLock.unlock() }
        let origin = String(format: "%.3f", sessionOrigin)
        let skew = String(format: "%.3f", (audio.origin ?? 0) - (video.origin ?? 0))
        return "sessionOrigin=\(origin);renditionSkew=\(skew);"
            + "videoFinished=\(video.finished);audioFinished=\(audio.finished);"
            + "videoOrigin=\(video.urlIndex + 1)/\(video.urls.count);"
            + "audioOrigin=\(audio.urlIndex + 1)/\(audio.urls.count);"
            + "replacements=\(video.replacements + audio.replacements);"
            + "position=\(String(format: "%.3f", lastEmittedSeconds))"
    }

    // MARK: - Internal

    /// Keep at most one packet in flight per rendition. The pull model is the back-pressure:
    /// a rendition that runs ahead in time simply holds its single packet until the schedule
    /// asks for it, so neither side can queue up against a stalled or slow peer.
    private func fill(_ side: inout Side, isCurrent: @Sendable () -> Bool) throws {
        guard side.pending == nil, !side.finished else { return }
        guard !closed.load(ordering: .acquiring) else { throw CancellationError() }
        do {
            try readInto(&side, isCurrent: isCurrent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A rendition that stops being readable is replaced from its own alternates and the
            // session is re-anchored; only an exhausted list ends the session. Silent video is
            // never the degradation: the failure is classified and thrown.
            guard try replaceRendition(&side, after: error, isCurrent: isCurrent) else {
                if side.isVideo { throw SeparatedPacketSourceError.videoUnreadable(error) }
                throw SeparatedPacketSourceError.audioUnreadable(error)
            }
            try readInto(&side, isCurrent: isCurrent)
        }
    }

    private func readInto(_ side: inout Side, isCurrent: @Sendable () -> Bool) throws {
        guard let demuxer = activeDemuxer(side) else {
            side.finished = true
            return
        }
        // The owner is read through the sequence entry point so its own separated dispatch is
        // bypassed; a replacement child has no such dispatch and uses the ordinary read.
        let isOwner = side.demuxer == nil
        func next() throws -> UnsafeMutablePointer<AVPacket>? {
            isOwner ? try demuxer.readPacketForSequence(isCurrent: isCurrent)
                    : try demuxer.readPacket(isCurrent: isCurrent)
        }
        var packet = try next()
        // A rendition may carry streams the merged table does not expose; drop those rather
        // than emitting a packet whose stream index has no entry.
        while let candidate = packet, candidate.pointee.stream_index != side.streamIndex {
            var scratch: UnsafeMutablePointer<AVPacket>? = candidate
            trackedPacketFree(&scratch)
            packet = try next()
        }
        guard let packet else {
            side.finished = true
            return
        }
        side.pending = packet
    }

    /// Swap one rendition for its next alternate origin and re-anchor the session.
    ///
    /// A replacement is only accepted when it describes the same stream — same media type, codec,
    /// and the geometry or audio layout the decoder was configured for — because the decoder keeps
    /// running across the swap and a different stream would corrupt it rather than recover it.
    /// The other rendition is never swapped to compensate for this one.
    private func replaceRendition(_ side: inout Side, after failure: Error,
                                  isCurrent: @Sendable () -> Bool) throws -> Bool {
        guard !closed.load(ordering: .acquiring) else { throw CancellationError() }
        guard let reference = rawStream(for: side)?.pointee.codecpar else { return false }
        let expected = CodecIdentity(reference)

        while side.hasAlternate {
            guard isCurrent(), !closed.load(ordering: .acquiring) else { throw CancellationError() }
            side.urlIndex += 1
            let url = side.urls[side.urlIndex]
            let candidate = Demuxer()
            children.withLock { $0.append(candidate) }
            do {
                try candidate.open(url: url, extraHeaders: headers, profile: profile, isLive: false)
            } catch {
                retire(candidate)
                continue
            }
            let index = candidate.firstStreamIndex(ofType: side.mediaType)
            guard index >= 0,
                  let replacement = candidate.rawStream(at: index)?.pointee.codecpar,
                  CodecIdentity(replacement) == expected else {
                EngineLog.emit("[SeparatedPacketSource] rejected \(side.isVideo ? "video" : "audio") "
                               + "alternate: it does not describe the same stream", category: .demux)
                retire(candidate)
                continue
            }

            let previous = side.demuxer
            side.demuxer = candidate
            side.streamIndex = index
            side.origin = Self.startSeconds(of: candidate, streamIndex: index)
            side.finished = false
            side.replacements += 1
            if let previous { retire(previous) }

            // Both renditions move in one operation: a replacement that only repositioned its own
            // side would leave the two playing from different instants.
            guard seek(to: lastEmittedSeconds) else {
                EngineLog.emit("[SeparatedPacketSource] alternate opened but the joint re-anchor "
                               + "to \(lastEmittedSeconds)s failed", category: .demux)
                continue
            }
            EngineLog.emit("[SeparatedPacketSource] replaced the \(side.isVideo ? "video" : "audio") "
                           + "rendition after \(failure) and re-anchored at \(lastEmittedSeconds)s",
                           category: .demux)
            return true
        }
        return false
    }

    /// What a replacement rendition has to match for the running decoder to survive the swap.
    private struct CodecIdentity: Equatable {
        let type: AVMediaType
        let id: AVCodecID
        let width: Int32
        let height: Int32
        let sampleRate: Int32
        let channels: Int32

        init(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) {
            type = codecpar.pointee.codec_type
            id = codecpar.pointee.codec_id
            width = codecpar.pointee.width
            height = codecpar.pointee.height
            sampleRate = codecpar.pointee.sample_rate
            channels = codecpar.pointee.ch_layout.nb_channels
        }
    }

    private func take(_ side: inout Side) -> UnsafeMutablePointer<AVPacket>? {
        guard let packet = side.pending else { return nil }
        side.pending = nil
        // Remember where the timeline had reached, so a rendition replaced later re-anchors to
        // this instant rather than to the start of the programme.
        let position = scheduleSeconds(of: packet, in: side) - sessionOrigin
        if position.isFinite, position >= 0 { lastEmittedSeconds = max(lastEmittedSeconds, position) }
        return rebase(packet, in: side)
    }

    /// Shift onto the session axis and re-index onto the merged table. The packet keeps its own
    /// stream's time base, because that same `AVStream` is what `stream(at:)` hands the decoder.
    private func rebase(_ packet: UnsafeMutablePointer<AVPacket>,
                        in side: Side) -> UnsafeMutablePointer<AVPacket> {
        if sessionOrigin != 0, let stream = rawStream(for: side) {
            let tb = stream.pointee.time_base
            if tb.num > 0, tb.den > 0 {
                let ticks = Int64((sessionOrigin * Double(tb.den) / Double(tb.num)).rounded())
                if packet.pointee.pts != Int64.min { packet.pointee.pts = packet.pointee.pts &- ticks }
                if packet.pointee.dts != Int64.min { packet.pointee.dts = packet.pointee.dts &- ticks }
            }
        }
        packet.pointee.stream_index = side.isVideo ? Self.videoIndex : Self.audioIndex
        packet.pointee.pos = -1
        return packet
    }

    /// Decode-order position on the shared seconds axis. DTS is the scheduling key; a packet
    /// with no DTS falls back to PTS so it is still ordered rather than pinned at zero.
    private func scheduleSeconds(of packet: UnsafeMutablePointer<AVPacket>, in side: Side) -> Double {
        guard let stream = rawStream(for: side) else { return 0 }
        let tb = stream.pointee.time_base
        guard tb.num > 0, tb.den > 0 else { return 0 }
        let stamp = packet.pointee.dts != Int64.min ? packet.pointee.dts : packet.pointee.pts
        guard stamp != Int64.min else { return 0 }
        return Double(stamp) * Double(tb.num) / Double(tb.den)
    }

    /// The demuxer this rendition currently reads from: its own child once it has been replaced,
    /// otherwise the owner for video and the child opened in `prepare()` for audio.
    private func activeDemuxer(_ side: Side) -> Demuxer? {
        side.demuxer ?? (side.isVideo ? owner : nil)
    }

    private func rawStream(for side: Side) -> UnsafeMutablePointer<AVStream>? {
        activeDemuxer(side)?.rawStream(at: side.streamIndex)
    }

    private func retire(_ demuxer: Demuxer) {
        children.withLock { list in list.removeAll { $0 === demuxer } }
        demuxer.close()
    }

    private func discardPending() {
        trackedPacketFree(&video.pending)
        trackedPacketFree(&audio.pending)
    }

    private static func startSeconds(of demuxer: Demuxer, streamIndex: Int32) -> Double? {
        guard let stream = demuxer.rawStream(at: streamIndex) else { return nil }
        let start = stream.pointee.start_time
        let tb = stream.pointee.time_base
        guard start != Int64.min, tb.num > 0, tb.den > 0 else { return nil }
        return Double(start) * Double(tb.num) / Double(tb.den)
    }
}

enum SeparatedPacketSourceError: Error, CustomStringConvertible {
    case unavailable
    case videoStreamMissing
    case audioStreamMissing
    case videoUnreadable(Error)
    case audioUnreadable(Error)

    var description: String {
        switch self {
        case .unavailable: "separated source has no open video rendition"
        case .videoStreamMissing: "separated video rendition carries no video stream"
        case .audioStreamMissing: "separated audio rendition carries no audio stream"
        case .videoUnreadable(let error): "separated video rendition failed: \(error)"
        case .audioUnreadable(let error): "separated audio rendition failed: \(error)"
        }
    }
}
