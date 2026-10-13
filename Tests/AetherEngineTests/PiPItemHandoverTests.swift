import Testing
@testable import AetherEngine

/// AE#158: a system PiP window closes the moment its source layer's player drops its item, so a
/// native->native load while PiP is active keeps the running item attached until the new master
/// swaps in place. A host that mounts the engine's own player layer can request the same handover
/// for a foreground episode change. See AetherEngine.shouldHandOverItemInPlace.
@Suite("In-place item handover policy")
struct PiPItemHandoverTests {
    @Test("hands over in place while PiP is active on a native session")
    func handsOverForNativePiP() {
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: true, priorBackendWasNative: true) == true)
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: false, priorBackendWasNative: true) == false)
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: true, priorBackendWasNative: false) == false)
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: false, priorBackendWasNative: false) == false)
    }

    @Test("a host request hands over in place on a native session without PiP")
    func handsOverForHostRequest() {
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: false, hostRequested: true, priorBackendWasNative: true) == true)
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: true, hostRequested: true, priorBackendWasNative: true) == true)
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: false, hostRequested: true, priorBackendWasNative: false) == false)
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: false, hostRequested: false, priorBackendWasNative: true) == false)
    }

    @Test("the host request is consumed by exactly one load decision")
    @MainActor
    func hostRequestIsOneShot() throws {
        let engine = try AetherEngine()
        engine.prepareForItemReplacement()
        #expect(engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true) == true)
        #expect(engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true) == false)
    }

    @Test("a non-native outgoing session consumes the request without handing over")
    @MainActor
    func hostRequestOnNonNativeIsConsumed() throws {
        let engine = try AetherEngine()
        engine.prepareForItemReplacement()
        #expect(engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: false) == false)
        #expect(engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true) == false)
    }

    @Test("stop() cancels a pending host request")
    @MainActor
    func stopCancelsHostRequest() throws {
        let engine = try AetherEngine()
        engine.prepareForItemReplacement()
        engine.stop()
        #expect(engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true) == false)
    }

    @Test("PiP still hands over with or without a host request")
    @MainActor
    func pipHandoverIndependentOfHostRequest() throws {
        let engine = try AetherEngine()
        engine.pictureInPictureActive = true
        #expect(engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true) == true)
        engine.prepareForItemReplacement()
        #expect(engine.consumeInPlaceItemHandoverRequest(priorBackendWasNative: true) == true)
        engine.pictureInPictureActive = false
    }
}
