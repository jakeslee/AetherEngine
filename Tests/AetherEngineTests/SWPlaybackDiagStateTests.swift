import Testing
import Foundation
@testable import AetherEngine

/// AE#479: the `[SWDiag]` audio marker after a seek.
///
/// `lastAudioPts` is the newest audio the pump enqueued, written by the pump alone. A seek flushes the
/// audio queue on the main actor while the pump is still on the pre-seek generation: after a playing
/// seek the pump writes its stale local once more before it notices the generation, and a seek that
/// lands paused parks the pump in its pause wait, where it writes nothing until `play()`. Either way
/// the line printed the old PTS against the re-anchored clock (`aLead=475.49` on a backward scrub in
/// the field, `-23.89` on a forward one on the harness), for one tick or for the whole paused stretch.
@Suite("SWPlaybackDiagState")
struct SWPlaybackDiagStateTests {

    @Test("A write from before the flush cannot republish the flushed queue's PTS")
    func staleWriteIsRefusedForTheMarker() {
        let diag = SWPlaybackDiagState()
        diag.update(lastAudioPts: 16.11, parked: 95, rebuffering: false, generation: 0)
        // The seek path: bump to generation 1, flush, tell the box.
        diag.audioFlushed(generation: 1)
        #expect(diag.snapshot.lastAudioPts.isNaN)
        // The pump's one late write from the iteration that was in flight when the seek arrived.
        diag.update(lastAudioPts: 16.11, parked: 95, rebuffering: false, generation: 0)
        #expect(diag.snapshot.lastAudioPts.isNaN)
    }

    @Test("parked and rebuffering are the pump's own state and land regardless of generation")
    func pumpStateStaysUnconditional() {
        let diag = SWPlaybackDiagState()
        diag.audioFlushed(generation: 3)
        diag.update(lastAudioPts: 16.11, parked: 42, rebuffering: true, generation: 1)
        let s = diag.snapshot
        #expect(s.lastAudioPts.isNaN)
        #expect(s.parked == 42)
        #expect(s.rebuffering)
    }

    @Test("The first write on the post-seek generation publishes the fresh marker")
    func freshWriteLands() {
        let diag = SWPlaybackDiagState()
        diag.update(lastAudioPts: 16.11, parked: 95, rebuffering: false, generation: 0)
        diag.audioFlushed(generation: 1)
        diag.update(lastAudioPts: 44.01, parked: 12, rebuffering: false, generation: 1)
        #expect(diag.snapshot.lastAudioPts == 44.01)
    }

    @Test("A superseded seek's flush cannot undo the newer one")
    func olderFlushDoesNotRegress() {
        let diag = SWPlaybackDiagState()
        diag.audioFlushed(generation: 2)
        diag.update(lastAudioPts: 44.01, parked: 12, rebuffering: false, generation: 2)
        // A seek from generation 1 finishing its main-actor prologue late.
        diag.audioFlushed(generation: 1)
        #expect(diag.snapshot.lastAudioPts == 44.01)
    }

    @Test("A pump that started on a later generation than the box writes normally")
    func pumpAheadOfBoxWrites() {
        // A host seeks before its pump is up: the pump captures the current generation on entry and
        // must not be refused by a box that has never seen a flush.
        let diag = SWPlaybackDiagState()
        diag.update(lastAudioPts: 4.0, parked: 1, rebuffering: false, generation: 7)
        #expect(diag.snapshot.lastAudioPts == 4.0)
    }
}
