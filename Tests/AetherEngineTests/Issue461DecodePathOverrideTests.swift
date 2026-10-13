import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// AE#461: `LoadOptions.preferredDecodePath` is the per-session escape onto `SoftwarePlaybackHost`
/// for the formats `VTCapabilityProbe` deliberately cannot classify. The probe fails open by design
/// (four classes keep the native path), which is right and occasionally wrong: when VideoToolbox
/// then cannot build a decoder for what arrives, the item reaches `readyToPlay` and renders nothing.
/// Before this the only per-session route onto that host was presenting a reader whose seek fails,
/// which costs the source its seeks, its audio switch, its title switch and the reload itself.
struct Issue461DecodePathOverrideTests {

    @Test("automatic leaves the routing exactly as it found it")
    func automaticIsTransparent() {
        #expect(VideoRoutingPolicy.usesSoftwarePath(routedSoftware: false, preferred: .automatic) == false)
        #expect(VideoRoutingPolicy.usesSoftwarePath(routedSoftware: true, preferred: .automatic) == true)
    }

    @Test("software overrides a native route")
    func softwareOverridesNative() {
        #expect(VideoRoutingPolicy.usesSoftwarePath(routedSoftware: false, preferred: .software))
    }

    @Test("software on an already-software route changes nothing")
    func softwareOnSoftwareIsIdempotent() {
        #expect(VideoRoutingPolicy.usesSoftwarePath(routedSoftware: true, preferred: .software))
    }

    /// The override is one-way by construction, and the type is the guarantee: there is no `.native`
    /// case to write. Every route the engine sends to software it sends there because the native
    /// path cannot serve it, so a native preference would buy a black screen. If a case is ever
    /// added, this fails and the one-way claim in the docs has to be revisited with it.
    @Test("there is no preference that can pull a session off the software path")
    func overrideIsOneWay() {
        #expect(DecodePath.allCases == [.automatic, .software])
        for preferred in DecodePath.allCases {
            #expect(VideoRoutingPolicy.usesSoftwarePath(routedSoftware: true, preferred: preferred),
                    "a software route stayed software for every preference")
        }
    }

    @Test("the default is the engine's own routing")
    func defaultIsAutomatic() {
        #expect(LoadOptions().preferredDecodePath == .automatic)
    }

    /// The override decides which host serves the session, not what that host can represent. These
    /// two guards run AFTER the routing decision in `load`, so forcing software onto an IPT-only
    /// Dolby Vision source still fails the load rather than decoding it as YCbCr and rendering
    /// green/purple. Pinned here because the override is exactly the change that could have been
    /// written to bypass them.
    @Test("forcing software does not make an IPT-only source representable")
    func overrideDoesNotSuspendTheColourGuard() {
        #expect(VideoRoutingPolicy.softwarePathCannotRepresent(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5, dvBlCompatID: nil))
        #expect(VideoRoutingPolicy.softwarePathCannotRepresent(
            codecID: AV_CODEC_ID_AV1, dvProfile: 10, dvBlCompatID: 0))
        // P7 / P8.x carry a decodable base layer and stay software-eligible, with or without an override.
        #expect(!VideoRoutingPolicy.softwarePathCannotRepresent(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 8, dvBlCompatID: 1))
    }
}

/// AE#461 composes with #460: correcting a running session onto the software path is a
/// `preferredDecodePath` change carried by the session-preserving reload.
@MainActor
struct Issue461ComposesWithReloadTests {

    @Test("the decode path is a correction lever, not part of the load identity")
    func decodePathIsCorrectable() {
        let base = LoadOptions()
        var proposed = base
        proposed.preferredDecodePath = .software
        #expect(SessionOptionCorrection.refusedFields(from: base, to: proposed).isEmpty)
        #expect(SessionOptionCorrection.changedFields(from: base, to: proposed) == ["preferredDecodePath"])
    }

    @Test("a correction that only changes the decode path reaches the session")
    func correctionInstallsTheDecodePath() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions())
        var corrected = engine.loadedOptions
        corrected.preferredDecodePath = .software
        engine.applySessionOptionCorrection(corrected)
        #expect(engine.loadedOptions.preferredDecodePath == .software)
    }
}
