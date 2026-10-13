import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// AE#461 follow-up: a mid-play decode-path correction has to reach the rebuild that keeps the
/// retained reader, and be refused before teardown when the software path cannot serve the source.
///
/// `preferredDecodePath` was read only inside `load`, while the custom-source rebuild picks its host
/// from the backend the session was already on. A correction on that shape was therefore accepted,
/// logged as applied and then ignored, which is the one outcome #460's own rules forbid: a
/// correction either lands or is refused by name, never three quarters of the way.
///
/// The direction is what makes the rebuild safe to re-route at all. `DecodePath` has no `.native`,
/// so the only flip reachable here is native -> software, and the software path is the general one.
/// The reverse (`loadNative` on a software-routed AV1 source, `unsupportedCodec`) stays unreachable
/// by construction rather than by a comment asking the next reader not to write it.
struct Issue461CustomSourceDecodePathTests {

    // MARK: the rebuild's route

    /// The rebuild must ask the same pure policy `load` asks, seeded with the backend it is on.
    /// A rebuild that reads `wasOnSoftwarePath` alone cannot honour a correction, which is the bug.
    @Test("a native session with a software preference rebuilds on software")
    func nativeSessionFlipsWhenCorrected() {
        #expect(VideoRoutingPolicy.usesSoftwarePath(routedSoftware: false, preferred: .software))
    }

    @Test("an uncorrected rebuild stays on the backend it was on")
    func uncorrectedRebuildIsUnchanged() {
        #expect(VideoRoutingPolicy.usesSoftwarePath(routedSoftware: false, preferred: .automatic) == false)
        #expect(VideoRoutingPolicy.usesSoftwarePath(routedSoftware: true, preferred: .automatic))
    }

    // MARK: the refusal, raised before any teardown

    /// The ordinary case: a native session on a plain codec is exactly the population the escape was
    /// built for, so the correction is honoured and nothing is refused.
    @Test("a plain native session accepts the correction")
    func plainSessionIsNotRefused() {
        #expect(SessionOptionCorrection.decodePathRefusal(
            routedSoftware: false,
            preferred: .software,
            codecID: AV_CODEC_ID_H264,
            dvProfile: nil,
            dvBLCompatID: nil,
            isLive: false,
            hasCompanionAudioReader: false) == nil)
    }

    /// #176's colour guard runs after the routing decision inside `load`, so on the custom rebuild it
    /// would either be skipped (green/purple picture) or reached after `stopInternal` had already
    /// taken the session down. Neither is a refusal that costs nothing, so it is decided here.
    @Test("an IPT-only Dolby Vision source is refused instead of rendered as YCbCr")
    func iptOnlyDolbyVisionIsRefused() {
        #expect(SessionOptionCorrection.decodePathRefusal(
            routedSoftware: false,
            preferred: .software,
            codecID: AV_CODEC_ID_HEVC,
            dvProfile: 5,
            dvBLCompatID: 0,
            isLive: false,
            hasCompanionAudioReader: false) == .softwarePathCannotRepresentSource)

        #expect(SessionOptionCorrection.decodePathRefusal(
            routedSoftware: false,
            preferred: .software,
            codecID: AV_CODEC_ID_AV1,
            dvProfile: 10,
            dvBLCompatID: 0,
            isLive: false,
            hasCompanionAudioReader: false) == .softwarePathCannotRepresentSource)
    }

    /// P8.1 and P10.1 carry a decodable base layer, so they are software-eligible and the correction
    /// is honoured. The refusal has to be narrow or it takes the escape away from the sources that
    /// can use it.
    @Test("a Dolby Vision source with a decodable base layer is not refused")
    func dolbyVisionWithBaseLayerIsAccepted() {
        #expect(SessionOptionCorrection.decodePathRefusal(
            routedSoftware: false,
            preferred: .software,
            codecID: AV_CODEC_ID_HEVC,
            dvProfile: 8,
            dvBLCompatID: 1,
            isLive: false,
            hasCompanionAudioReader: false) == nil)

        #expect(SessionOptionCorrection.decodePathRefusal(
            routedSoftware: false,
            preferred: .software,
            codecID: AV_CODEC_ID_AV1,
            dvProfile: 10,
            dvBLCompatID: 1,
            isLive: false,
            hasCompanionAudioReader: false) == nil)
    }

    /// The side-audio merge lives in `HLSSegmentProducer`, on the native path. A demuxed-audio live
    /// source moved onto the software path plays silent, and `load` fails it for that reason; the
    /// correction is refused for the same reason, one teardown earlier.
    @Test("a demuxed-audio live source is refused rather than played silent")
    func demuxedAudioLiveIsRefused() {
        #expect(SessionOptionCorrection.decodePathRefusal(
            routedSoftware: false,
            preferred: .software,
            codecID: AV_CODEC_ID_H264,
            dvProfile: nil,
            dvBLCompatID: nil,
            isLive: true,
            hasCompanionAudioReader: true) == .demuxedAudioLiveIsNativeOnly)
    }

    /// A companion reader on a VOD session is not the demuxed-audio live shape, and live on its own
    /// is the rung the escape exists for. Neither may borrow the other's refusal.
    @Test("live alone and a companion reader alone are both accepted")
    func neitherHalfOfTheLiveGuardRefusesAlone() {
        #expect(SessionOptionCorrection.decodePathRefusal(
            routedSoftware: false, preferred: .software, codecID: AV_CODEC_ID_H264,
            dvProfile: nil, dvBLCompatID: nil,
            isLive: true, hasCompanionAudioReader: false) == nil)

        #expect(SessionOptionCorrection.decodePathRefusal(
            routedSoftware: false, preferred: .software, codecID: AV_CODEC_ID_H264,
            dvProfile: nil, dvBLCompatID: nil,
            isLive: false, hasCompanionAudioReader: true) == nil)
    }

    /// A refusal is about the flip, not about the field. A session already on the software path is
    /// not moved anywhere by a software preference, so there is nothing to refuse: refusing there
    /// would break the plain reload of every source that legitimately routes software.
    @Test("a session already on the software path is never refused")
    func alreadySoftwareIsNeverRefused() {
        for isLive in [false, true] {
            #expect(SessionOptionCorrection.decodePathRefusal(
                routedSoftware: true, preferred: .software, codecID: AV_CODEC_ID_HEVC,
                dvProfile: 5, dvBLCompatID: 0,
                isLive: isLive, hasCompanionAudioReader: true) == nil)
        }
    }

    /// An uncorrected reload of a native session must not be refused by the source facts either, or
    /// every audio switch on a Dolby Vision source would start throwing.
    @Test("an automatic preference is never refused")
    func automaticIsNeverRefused() {
        #expect(SessionOptionCorrection.decodePathRefusal(
            routedSoftware: false, preferred: .automatic, codecID: AV_CODEC_ID_HEVC,
            dvProfile: 5, dvBLCompatID: 0,
            isLive: true, hasCompanionAudioReader: true) == nil)
    }

    /// The refusals say which one they are, in the thrown error and in the log, because a host that
    /// has to choose between falling back to its own player and leaving the session alone needs the
    /// difference.
    @Test("the two refusals are distinguishable and described")
    func refusalsAreDistinct() {
        #expect(SessionReloadRefusal.softwarePathCannotRepresentSource
                != SessionReloadRefusal.demuxedAudioLiveIsNativeOnly)
        for refusal in [SessionReloadRefusal.softwarePathCannotRepresentSource,
                        .demuxedAudioLiveIsNativeOnly] {
            #expect(!refusal.rawValue.isEmpty)
            #expect(!refusal.description.isEmpty)
        }
    }
}
