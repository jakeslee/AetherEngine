import Foundation
import AVFoundation
import CoreMedia
import Testing
import AetherLibavutil
@testable import AetherEngine

/// AE#464: the audio presentation offset. These pin the two things about it that are easy to get
/// wrong and impossible to see afterwards: WHERE on each route the offset may be applied, and what
/// happens to a session that tries to change it without re-anchoring.
@Suite("AE#464 audio delay policy")
struct Issue464AudioDelayPolicyTests {

    @Test("the bound holds in both directions and a non-finite value collapses to zero")
    func clamping() {
        #expect(AudioDelayPolicy.clamp(0.15) == 0.15)
        #expect(AudioDelayPolicy.clamp(-0.15) == -0.15)
        #expect(AudioDelayPolicy.clamp(9.0) == AudioDelayPolicy.maxAbsSeconds)
        #expect(AudioDelayPolicy.clamp(-9.0) == -AudioDelayPolicy.maxAbsSeconds)
        // An unset stepper reads back NaN often enough to be worth naming: it must not reach a
        // timestamp, where it would poison every packet the session writes rather than one value.
        #expect(AudioDelayPolicy.clamp(.nan) == 0)
        #expect(AudioDelayPolicy.clamp(.infinity) == 0)
    }

    @Test("out-of-range is reported so the delivered offset is never silently not the one set")
    func outOfRangeIsVisible() {
        #expect(!AudioDelayPolicy.isOutOfRange(0.25))
        #expect(!AudioDelayPolicy.isOutOfRange(AudioDelayPolicy.maxAbsSeconds))
        #expect(AudioDelayPolicy.isOutOfRange(AudioDelayPolicy.maxAbsSeconds + 0.001))
        #expect(AudioDelayPolicy.isOutOfRange(.nan))
    }

    @Test("the bound stays inside the muxer's interleave window, which a constant offset consumes")
    func boundFitsTheInterleaveWindow() {
        // A constant A/V offset costs the interleaver |delay| of buffering. The muxer's floor is 8 s
        // (MP4SegmentMuxer construction in HLSSegmentProducer), so a bound at or above it would let a
        // host trade lip-sync for a stalled interleaver.
        #expect(AudioDelayPolicy.maxAbsSeconds < 8.0)
    }

    @Test("every route says where its offset lands, and the two AVPlayer-owned ones say they cannot")
    func routeMapping() {
        #expect(AudioDelayPolicy.application(for: .software) == .sampleTimestamps)
        #expect(AudioDelayPolicy.application(for: .loopback) == .segmentTimestamps)
        // Not an oversight and not a defect: on remoteBypass AVPlayer holds the media, and an
        // audio-only session has no video for audio to be early or late against.
        #expect(AudioDelayPolicy.application(for: .remoteBypass) == .unavailable)
        #expect(AudioDelayPolicy.application(for: .audio) == .unavailable)
        #expect(AudioDelayPolicy.application(for: .none) == .unavailable)
    }

    @Test("setting the value already in force is not a change, so it cannot cost a re-cut")
    func redundantSetIsNoChange() {
        #expect(!AudioDelayPolicy.isChange(from: 0.1, to: 0.1))
        #expect(AudioDelayPolicy.isChange(from: 0.1, to: 0.15))
        #expect(AudioDelayPolicy.isChange(from: 0, to: -0.05))
    }
}

/// The offset in the fMP4 muxer's own time base.
@Suite("AE#464 muxer audio delay conversion")
struct Issue464MuxerDelayTicksTests {

    @Test("seconds convert into the muxer's OUTPUT audio time base")
    func conversion() {
        let tb48k = AVRational(num: 1, den: 48000)
        #expect(MP4SegmentMuxer.audioDelayTicks(seconds: 0.100, audioTimeBase: tb48k) == 4800)
        #expect(MP4SegmentMuxer.audioDelayTicks(seconds: -0.250, audioTimeBase: tb48k) == -12000)
        #expect(MP4SegmentMuxer.audioDelayTicks(seconds: 0, audioTimeBase: tb48k) == 0)
    }

    @Test("a sub-tick nudge rounds toward the direction asked for instead of truncating to nothing")
    func roundsRatherThanTruncates() {
        // 1/1000 s base: 40 ms of a 44.1 kHz-ish nudge must not become 0 because Int64() truncates.
        let tbMs = AVRational(num: 1, den: 1000)
        #expect(MP4SegmentMuxer.audioDelayTicks(seconds: 0.0006, audioTimeBase: tbMs) == 1)
        #expect(MP4SegmentMuxer.audioDelayTicks(seconds: -0.0006, audioTimeBase: tbMs) == -1)
    }

    @Test("a degenerate or non-finite input yields no shift rather than a poisoned timestamp")
    func degenerateInputs() {
        #expect(MP4SegmentMuxer.audioDelayTicks(seconds: 0.1, audioTimeBase: AVRational(num: 0, den: 0)) == 0)
        #expect(MP4SegmentMuxer.audioDelayTicks(seconds: .nan, audioTimeBase: AVRational(num: 1, den: 48000)) == 0)
        #expect(MP4SegmentMuxer.audioDelayTicks(seconds: .infinity, audioTimeBase: AVRational(num: 1, den: 48000)) == 0)
    }
}

/// Why the offset is applied where it is. Both of these pin behaviour of code the offset does NOT
/// live in: they are the reason it does not live there.
@Suite("AE#464 why the obvious places are wrong")
struct Issue464PlacementRationaleTests {

    @Test("the gapless clock absorbs a sub-100 ms step, so an offset upstream of it would vanish")
    func gaplessAnchorSwallowsASmallOffset() {
        // The naive software implementation adds the delay to the container PTS before stamping.
        // AudioClockAnchor reads anything below its discontinuity threshold as container rounding and
        // keeps predicting from its own sample count, so a 50 ms nudge would produce no change at all
        // and a host would report the setter as dead. This is that mechanism, stated.
        var clock = AudioClockAnchor()
        let rate: Int32 = 48000
        let first = CMTime(value: 0, timescale: rate)
        let (p0, r0) = clock.resolve(startPTS: first, sampleRate: rate)
        clock.commit(pts: p0, reanchor: r0, sampleCount: 1024)

        let naturalNext = CMTime(value: 1024, timescale: rate)
        let nudged = CMTimeAdd(naturalNext, CMTime(seconds: 0.05, preferredTimescale: rate))
        let (p1, r1) = clock.resolve(startPTS: nudged, sampleRate: rate)
        #expect(!r1, "a 50 ms step is below the discontinuity threshold, so it does not re-anchor")
        #expect(p1 == naturalNext, "the offset was absorbed: the stamped PTS is the predicted one")
    }

    @Test("a backwards audio step is clamped away, so a smaller offset cannot be spliced mid-track")
    func sanitizerEatsABackwardsStep() {
        // The naive loopback implementation lowers the muxer's offset and keeps cutting into the same
        // output track. OutputTimestampSanitizer enforces strictly increasing DTS per stream, so the
        // overlap the change creates is not delivered: it is clamped to last+1 and the audio stays
        // where it was. Hence one offset per muxer, and a producer restart to change it.
        var sanitizer = OutputTimestampSanitizer()
        let audio: Int32 = 1
        _ = sanitizer.sanitize(streamIndex: audio, pts: 48000, dts: 48000)
        let stepBack = sanitizer.sanitize(streamIndex: audio, pts: 43200, dts: 43200)   // -100 ms @48k
        #expect(stepBack.dts == 48001, "the backwards step was clamped, not honoured")
        #expect(stepBack.pts >= stepBack.dts)
    }
}

/// The software path's shift, on a real CMSampleBuffer.
@Suite("AE#464 sample retiming")
struct Issue464SampleRetimingTests {

    private func makeBuffer(pts: CMTime, samples: Int = 1024, sampleRate: Int32 = 48000) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &asbd,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: samples * 4,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: samples * 4,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let block else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: sampleRate),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                   dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format,
                                   sampleCount: CMItemCount(samples),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    @Test("a positive offset moves the delivered stamp later, and the payload is untouched")
    func shiftsLater() throws {
        let source = CMTime(value: 48000, timescale: 48000)   // 1.000 s
        let buffer = try #require(makeBuffer(pts: source))
        let shifted = AudioOutput.retimed(buffer, by: CMTime(seconds: 0.2, preferredTimescale: 90000))

        let out = CMSampleBufferGetPresentationTimeStamp(shifted).seconds
        #expect(abs(out - 1.2) < 0.0001, "delivered 200 ms later, got \(out)")
        #expect(CMSampleBufferGetNumSamples(shifted) == CMSampleBufferGetNumSamples(buffer))
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(buffer).seconds - 1.0) < 0.0001,
                "the source buffer is not mutated: the audio tap is handed that one")
    }

    @Test("a negative offset moves it earlier")
    func shiftsEarlier() throws {
        let buffer = try #require(makeBuffer(pts: CMTime(value: 48000, timescale: 48000)))
        let shifted = AudioOutput.retimed(buffer, by: CMTime(seconds: -0.15, preferredTimescale: 90000))
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(shifted).seconds - 0.85) < 0.0001)
    }

    @Test("a zero offset hands back the very same buffer, so the common case costs no copy")
    func zeroIsFree() throws {
        let buffer = try #require(makeBuffer(pts: CMTime(value: 48000, timescale: 48000)))
        #expect(AudioOutput.retimed(buffer, by: .zero) === buffer)
    }
}

/// Whether a change can be brought to the playhead at all.
@MainActor
@Suite("AE#464 re-anchor eligibility")
struct Issue464RecutEligibilityTests {

    @Test("a session with a playhead re-anchors; one without keeps the value for the next seam")
    func stateMatrix() {
        #expect(AetherEngine.audioDelayRecutIsPossible(state: .playing, isLive: false, liveWindow: nil))
        #expect(AetherEngine.audioDelayRecutIsPossible(state: .paused, isLive: false, liveWindow: nil))
        #expect(AetherEngine.audioDelayRecutIsPossible(state: .seeking, isLive: false, liveWindow: nil))
        // The states seek() itself refuses. Setting the value is still honoured; only the re-anchor
        // is skipped, and the next load reads it out of the options.
        #expect(!AetherEngine.audioDelayRecutIsPossible(state: .idle, isLive: false, liveWindow: nil))
        #expect(!AetherEngine.audioDelayRecutIsPossible(state: .loading, isLive: false, liveWindow: nil))
        #expect(!AetherEngine.audioDelayRecutIsPossible(state: .ended, isLive: false, liveWindow: nil))
    }

    @Test("live without a DVR window has no position to come back to")
    func liveWithoutDVR() {
        // Round 2: these are the windows `load` actually builds, not a Bool a call site derives. The
        // gate used to be handed `liveWindow != nil`, which is true for BOTH of these, so the whole
        // live-only branch was unreachable and a live session took the re-anchor either way.
        #expect(!AetherEngine.audioDelayRecutIsPossible(
            state: .playing, isLive: true, liveWindow: LiveWindow(windowSeconds: nil)))
        #expect(AetherEngine.audioDelayRecutIsPossible(
            state: .playing, isLive: true, liveWindow: LiveWindow(windowSeconds: 1800)))
        // The remote-HLS live shape: `load` gives it an unbounded window, and it does rewind.
        #expect(AetherEngine.audioDelayRecutIsPossible(
            state: .playing, isLive: true, liveWindow: LiveWindow(windowSeconds: .greatestFiniteMagnitude)))
    }

    @Test("the gate agrees with the one the seek path uses, which is where the sessions actually meet")
    func agreesWithTheSeekRefusal() {
        // A live `.software` re-anchor is a `seek(origin: .host)`, so a gate that lets one through
        // that `seek` then refuses as `liveWithoutDVR` costs a teardown to change nothing. The two
        // rules have to read the same field, and this is what pins that they do.
        for window in [Double?.none, 1800, .greatestFiniteMagnitude] {
            let seekRefuses = AetherEngine.liveSeekRefusedWithoutDVR(origin: .host, windowSeconds: window)
            let gateAllows = AetherEngine.audioDelayRecutIsPossible(
                state: .playing, isLive: true, liveWindow: LiveWindow(windowSeconds: window))
            #expect(gateAllows == !seekRefuses)
        }
    }
}

/// The option that carries the value across the rebuilds a session makes on its own.
@MainActor
@Suite("AE#464 the offset is session tuning, not session identity")
struct Issue464LoadOptionTests {

    @Test("audioDelaySeconds is correctable mid-session by a reload-with-options")
    func isCorrectable() {
        // The #460 inventory guard makes a new field a decision. This is that decision, written down:
        // the offset does not name the session (it opens no different pipeline), so it is tuning.
        #expect(SessionOptionCorrection.knownFields.contains("audioDelaySeconds"))
        #expect(!SessionOptionCorrection.loadIdentityFields.contains("audioDelaySeconds"))
    }

    @Test("it defaults to untouched")
    func defaultsToZero() {
        #expect(LoadOptions().audioDelaySeconds == 0)
    }
}
