import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("Packet-level separated renditions")
struct SeparatedPacketSourceTests {
    private enum FixtureError: Error { case invalidFixture }

    /// A video-only rendition and an audio-only rendition, the shape DASH delivers.
    private func temporaryRenditions() throws -> (video: URL, audio: URL, directory: URL) {
        guard let videoData = Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                                   options: .ignoreUnknownCharacters),
              let audioData = Data(base64Encoded: AtmosDetectionProbeIntegrationTests.aacBase64,
                                   options: .ignoreUnknownCharacters) else {
            throw FixtureError.invalidFixture
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-separated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let video = directory.appendingPathComponent("video.mp4")
        let audio = directory.appendingPathComponent("audio.mp4")
        try videoData.write(to: video)
        try audioData.write(to: audio)
        return (video, audio, directory)
    }

    @Test("merged table exposes one video and one audio stream from two demuxers")
    func exposesMergedStreamTable() throws {
        let fixture = try temporaryRenditions()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(separated: SeparatedMedia(videoURL: fixture.video, audioURL: fixture.audio))

        #expect(demuxer.streamCount == 2)
        #expect(demuxer.videoStreamIndex == SeparatedPacketSource.videoIndex)
        #expect(demuxer.audioStreamIndex == SeparatedPacketSource.audioIndex)

        let video = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let audio = try #require(demuxer.stream(at: demuxer.audioStreamIndex))
        #expect(video.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO)
        #expect(audio.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO)
        // Each side keeps its own AVStream, so the decoder reads authentic codec parameters
        // rather than anything this source synthesized.
        #expect(audio.pointee.codecpar.pointee.sample_rate > 0)
        #expect(demuxer.isVideoStream(demuxer.videoStreamIndex))
        #expect(!demuxer.isVideoStream(demuxer.audioStreamIndex))
    }

    @Test("delivers both renditions interleaved in decode order")
    func interleavesBothRenditions() throws {
        let fixture = try temporaryRenditions()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(separated: SeparatedMedia(videoURL: fixture.video, audioURL: fixture.audio))

        var videoPackets = 0
        var audioPackets = 0
        var lastSchedule = -Double.greatestFiniteMagnitude
        var monotonic = true
        while let packet = try demuxer.readPacket() {
            let index = packet.pointee.stream_index
            if index == SeparatedPacketSource.videoIndex { videoPackets += 1 }
            if index == SeparatedPacketSource.audioIndex { audioPackets += 1 }
            if let stream = demuxer.stream(at: index) {
                let tb = stream.pointee.time_base
                let stamp = packet.pointee.dts != Int64.min ? packet.pointee.dts : packet.pointee.pts
                if stamp != Int64.min, tb.num > 0, tb.den > 0 {
                    let seconds = Double(stamp) * Double(tb.num) / Double(tb.den)
                    if seconds + 0.000_001 < lastSchedule { monotonic = false }
                    lastSchedule = max(lastSchedule, seconds)
                }
            }
            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }
        // Silent video is the failure this source exists to prevent: both sides must deliver.
        #expect(videoPackets > 0)
        #expect(audioPackets > 0)
        // Scheduling is by decode timestamp across the two renditions.
        #expect(monotonic)
    }

    @Test("reports a duration covering both renditions")
    func reportsProgrammeDuration() throws {
        let fixture = try temporaryRenditions()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(separated: SeparatedMedia(videoURL: fixture.video, audioURL: fixture.audio))
        #expect(demuxer.duration > 0)

        let declared = Demuxer()
        defer { declared.close() }
        try declared.open(separated: SeparatedMedia(videoURL: fixture.video,
                                                    audioURL: fixture.audio,
                                                    duration: 12.5))
        #expect(abs(declared.duration - 12.5) < 0.001)
    }

    @Test("joint seek repositions both renditions in one operation")
    func jointSeekMovesBothRenditions() throws {
        let fixture = try temporaryRenditions()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(separated: SeparatedMedia(videoURL: fixture.video, audioURL: fixture.audio))

        // Drain to the end so a successful seek has to be what rewinds both sides.
        while let packet = try demuxer.readPacket() {
            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }
        #expect(demuxer.seekBounded(to: 0, anchorStreamIndex: demuxer.videoStreamIndex, timeout: 2))

        var sawVideo = false
        var sawAudio = false
        var guardCount = 0
        while (!sawVideo || !sawAudio), guardCount < 4_096, let packet = try demuxer.readPacket() {
            guardCount += 1
            if packet.pointee.stream_index == SeparatedPacketSource.videoIndex { sawVideo = true }
            if packet.pointee.stream_index == SeparatedPacketSource.audioIndex { sawAudio = true }
            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }
        // A half-applied seek would leave one rendition at EOF and starve this loop.
        #expect(sawVideo)
        #expect(sawAudio)
    }

    @Test("an unreadable audio rendition fails the load instead of playing silent video")
    func missingAudioFailsTheLoad() throws {
        let fixture = try temporaryRenditions()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let absent = fixture.directory.appendingPathComponent("not-there.m4s")
        let demuxer = Demuxer()
        defer { demuxer.close() }
        #expect(throws: (any Error).self) {
            try demuxer.open(separated: SeparatedMedia(videoURL: fixture.video, audioURL: absent))
        }
    }

    @Test("a rendition carrying no audio stream is rejected")
    func audioRenditionWithoutAudioIsRejected() throws {
        let fixture = try temporaryRenditions()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        // Both sides point at the video-only rendition: there is no audio to join.
        #expect(throws: (any Error).self) {
            try demuxer.open(separated: SeparatedMedia(videoURL: fixture.video, audioURL: fixture.video))
        }
    }

    @Test("an unreadable primary audio origin falls back to its alternate")
    func audioFallsBackAtOpen() throws {
        let fixture = try temporaryRenditions()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let dead = fixture.directory.appendingPathComponent("gone.m4s")
        let demuxer = Demuxer()
        defer { demuxer.close() }
        // The primary origin is unreachable; the alternate carries the same audio.
        try demuxer.open(separated: SeparatedMedia(videoURL: fixture.video,
                                                   audioURL: dead,
                                                   audioFallbackURLs: [fixture.audio]))
        #expect(demuxer.streamCount == 2)
        let audio = try #require(demuxer.stream(at: demuxer.audioStreamIndex))
        #expect(audio.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO)

        var audioPackets = 0
        while let packet = try demuxer.readPacket() {
            if packet.pointee.stream_index == SeparatedPacketSource.audioIndex { audioPackets += 1 }
            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }
        #expect(audioPackets > 0)
    }

    @Test("an alternate that describes a different stream is refused")
    func incompatibleAlternateIsRefused() throws {
        let fixture = try temporaryRenditions()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let dead = fixture.directory.appendingPathComponent("gone.m4s")
        let demuxer = Demuxer()
        defer { demuxer.close() }
        // Both the primary and the alternate are wrong: the alternate carries video, not audio,
        // so accepting it would hand the audio decoder a stream it was never configured for.
        #expect(throws: (any Error).self) {
            try demuxer.open(separated: SeparatedMedia(videoURL: fixture.video,
                                                       audioURL: dead,
                                                       audioFallbackURLs: [fixture.video]))
        }
    }

    @Test("exhausting a rendition's alternates ends the session rather than playing one side")
    func exhaustedAlternatesFail() throws {
        let fixture = try temporaryRenditions()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let deadA = fixture.directory.appendingPathComponent("a.m4s")
        let deadB = fixture.directory.appendingPathComponent("b.m4s")
        let demuxer = Demuxer()
        defer { demuxer.close() }
        #expect(throws: (any Error).self) {
            try demuxer.open(separated: SeparatedMedia(videoURL: fixture.video,
                                                       audioURL: deadA,
                                                       audioFallbackURLs: [deadB]))
        }
    }

    @Test("closing releases the audio rendition without touching the owner twice")
    func closeReleasesChildDemuxer() throws {
        let fixture = try temporaryRenditions()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let demuxer = Demuxer()
        try demuxer.open(separated: SeparatedMedia(videoURL: fixture.video, audioURL: fixture.audio))
        let packet = try #require(try demuxer.readPacket())
        av_packet_unref(packet)
        av_packet_free_safe(packet)
        demuxer.close()
        // Idempotent: a second close must not double-free the child or the owner context.
        demuxer.close()
        #expect(demuxer.streamCount == 0)
    }
}
