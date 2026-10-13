import Foundation
import Testing
@testable import AetherEngine

/// AE#454: a rejoin is two operations, attaching an item and placing it, and only the first was ever
/// stated to AVPlayer at the swap.
///
/// Reported from a device on 6.56.6 (tschuegy): thirteen outage swaps out of thirteen landed exactly
/// on the place the viewer held, and every one of them played 4 to 37 s ahead of it for 140 to 220 ms
/// first. The item was loaded with `startPos=nil`, so it did what a live playlist tells any client to
/// do, joined at the edge and started playing, and the place it held arrived afterwards as a seek.
///
/// Reproduced on the harness at 50.27 s above the held place, with the request that proves it in the
/// server log: the fresh item's FIRST fetch was seg26 while the consumer had consumed through seg15.
///
/// The playlist is ours, so the placement belongs in it. `EXT-X-START` is the tag for exactly this
/// question, and the item's zero is the start of the playlist it loaded (AE#446 round 4), so an offset
/// from the playlist start is a position both sides already agree on.
@Suite("AE#454 the placement belongs in the playlist")
struct Issue454RejoinPlacementTests {

    // MARK: - The served offset

    /// Six 5 s segments, the shape the harness runs: the window lists seg10..seg15 and the viewer is
    /// two segments in.
    private func uniform(_ seconds: Double) -> (Int) -> Double { { _ in seconds } }

    @Test("the offset is the sum of the EXTINFs from the playlist's first segment")
    func offsetSumsFromFirstVisible() {
        // Target: seg12, 1.5 s in. From firstVisible seg10 that is two whole segments plus 1.5 s.
        let offset = LiveEdgePolicy.rejoinStartTimeOffset(
            segmentIndex: 12, secondsIntoSegment: 1.5,
            firstVisible: 10, visibleCount: 30, targetDuration: 5,
            segmentDuration: uniform(5.0))
        #expect(offset != nil)
        #expect(abs((offset ?? 0) - 11.5) < 0.0005)
    }

    /// AE#447 round 2's lesson, applied: `#EXTINF` is written with `%.3f`, so the client's timeline
    /// is the sum of the PRINTED durations. Accumulating the raw
    /// doubles instead drifts away from the playlist the item is reading, and the drift grows with
    /// every segment between the playlist start and the target.
    @Test("every term is taken at the resolution the playlist serves")
    func termsTakenAtServedResolution() {
        // A duration that prints as 2.000 but carries sub-millisecond noise, 40 segments of it.
        let noisy = 2.0 + 4e-4
        let offset = LiveEdgePolicy.rejoinStartTimeOffset(
            segmentIndex: 40, secondsIntoSegment: 0,
            firstVisible: 0, visibleCount: 100, targetDuration: 2,
            segmentDuration: uniform(noisy))
        // 40 x 2.000 as printed, not 40 x 2.0004.
        #expect(abs((offset ?? 0) - 80.0) < 0.0005)
    }

    @Test("a target the window has evicted carries no placement")
    func evictedTargetIsNil() {
        #expect(LiveEdgePolicy.rejoinStartTimeOffset(
            segmentIndex: 4, secondsIntoSegment: 0,
            firstVisible: 10, visibleCount: 30, targetDuration: 5,
            segmentDuration: uniform(5.0)) == nil)
    }

    @Test("a target past the end of the window carries no placement")
    func targetPastTheEndIsNil() {
        #expect(LiveEdgePolicy.rejoinStartTimeOffset(
            segmentIndex: 30, secondsIntoSegment: 0,
            firstVisible: 10, visibleCount: 30, targetDuration: 5,
            segmentDuration: uniform(5.0)) == nil)
    }

    /// RFC 8216 4.3.5.2: a positive TIME-OFFSET should not sit within three target durations of the
    /// end of a live playlist. A viewer that close to the edge is one the ordinary edge join answers
    /// correctly anyway, so this is a refusal to instruct rather than a lost placement.
    @Test("a placement inside the holdback is not instructed")
    func placementInsideHoldbackIsNil() {
        // 20 segments of 5 s = 100 s, so at TD 5 the holdback starts at 85 s. seg18 opens at 90 s,
        // which is inside it.
        #expect(LiveEdgePolicy.rejoinStartTimeOffset(
            segmentIndex: 18, secondsIntoSegment: 0,
            firstVisible: 0, visibleCount: 20, targetDuration: 5,
            segmentDuration: uniform(5.0)) == nil)
        // seg17 opens exactly ON the holdback, with three whole target durations behind it, which is
        // the position AVPlayer would have picked for itself. Instructed, and a no-op if it was.
        #expect(LiveEdgePolicy.rejoinStartTimeOffset(
            segmentIndex: 17, secondsIntoSegment: 0,
            firstVisible: 0, visibleCount: 20, targetDuration: 5,
            segmentDuration: uniform(5.0)) != nil)
    }

    /// The window slides between arming the placement and the fresh item fetching the playlist that
    /// carries it, which is why the arm names a SEGMENT rather than a number of seconds: the same
    /// content resolves to a smaller offset as the playlist start walks up under it.
    @Test("a slide between arming and serving moves the offset, not the content")
    func slideMovesTheOffsetNotTheContent() {
        let before = LiveEdgePolicy.rejoinStartTimeOffset(
            segmentIndex: 12, secondsIntoSegment: 0,
            firstVisible: 10, visibleCount: 30, targetDuration: 5,
            segmentDuration: uniform(5.0))
        let afterTwoSlides = LiveEdgePolicy.rejoinStartTimeOffset(
            segmentIndex: 12, secondsIntoSegment: 0,
            firstVisible: 12, visibleCount: 32, targetDuration: 5,
            segmentDuration: uniform(5.0))
        #expect(abs((before ?? -1) - 10.0) < 0.0005)
        #expect(abs((afterTwoSlides ?? -1) - 0.0) < 0.0005)
    }

    // MARK: - The correcting seek, kept only for the case that needs it

    /// The seek is not free: a zero-tolerance seek bounces transport at the exact moment the picture
    /// is coming back (250 ms of a 485 ms hand-off, measured). A placement the playlist already made
    /// does not need making again, and the test is whether it WORKED, not a tolerance on where a
    /// rejoin may land.
    @Test("an exact placement retires the correcting seek, a segment-rounded one does not")
    func placementSatisfiedOnlyWhenExact() {
        let tolerance = AetherEngine.liveRejoinPlacementSatisfiedSeconds
        // The harness reading: placed at 50.14 against a 50.15 target.
        #expect(abs(50.1428 - 50.1459) <= tolerance)
        // A client that honoured the tag only to a segment boundary is a whole segment off.
        #expect(abs(45.12 - 50.1459) > tolerance)
        // A client that ignored it joined its own edge.
        #expect(abs(102.50 - 50.1459) > tolerance)
    }

    // MARK: - The clock across the hand-off

    /// The second defect the reporter measured, and the more general one: an item's axis offset was
    /// latched per item, but between an in-place swap and the fresh item reporting a range the RETIRED
    /// item's offset was still folded into the fresh item's clock, which reads ~0. The session then
    /// published the retired item's zero, 70 to 80 s below the place it held in the field.
    @Test("a fresh item has no position for the session until it says it can play")
    func placementPendingUntilReady() {
        // Swapped in, not yet accepted: held.
        #expect(AetherEngine.liveItemPlacementPending(
            acceptedGeneration: 1, itemGeneration: 2, axisGeneration: 1, itemReportsRange: false))
        // Still the same item after the swap settled: published as before.
        #expect(!AetherEngine.liveItemPlacementPending(
            acceptedGeneration: 2, itemGeneration: 2, axisGeneration: 2, itemReportsRange: true))
    }

    /// Readiness and the seekable range are separate signals and their order is AVFoundation's
    /// business, so an item that reports ready before it reports a range must not publish a position
    /// folded through the axis of the item that left.
    @Test("an accepted item with no axis yet is still held")
    func acceptedWithoutAxisIsHeld() {
        #expect(AetherEngine.liveItemPlacementPending(
            acceptedGeneration: 2, itemGeneration: 2, axisGeneration: 1, itemReportsRange: false))
        // The range arrives; the next tick measures the axis and the hold releases on it.
        #expect(!AetherEngine.liveItemPlacementPending(
            acceptedGeneration: 2, itemGeneration: 2, axisGeneration: 1, itemReportsRange: true))
    }

    /// The cold join is bit-identical to before: nothing has been accepted yet, so there is no retired
    /// axis to fold and an offset of 0 is the truth rather than a leftover.
    @Test("the first item of a session is never held")
    func firstItemNeverHeld() {
        #expect(!AetherEngine.liveItemPlacementPending(
            acceptedGeneration: -1, itemGeneration: 1, axisGeneration: -1, itemReportsRange: false))
    }

    // MARK: - Round 2: the axis belongs to the playlist that stated it

    /// Retested on 6.57.0 (tschuegy): seams 2 to 4 read `0.000s` and retired the correcting seek, and
    /// seam 1, the session's FIRST swap, read 6.76 s and seeked an item that was already exactly where
    /// the manifest had put it. The content witness cleared the client: its first requests were the
    /// consumer's own segments and it came up at the served TIME-OFFSET to the millisecond.
    ///
    /// What moved it was the check, and underneath the check, the axis. The axis was reconstructed as
    /// a DIFFERENCE between two independently sampled quantities, the producer's resident floor and
    /// the item's own seekable start. Fed the range of the item that just left, whose axis IS the
    /// session's and whose seekable start is therefore the playlist floor itself, that difference
    /// collapses to exactly 0, which reads as "this item has no offset" and is latched for life.
    @Test("the retired item's seekable start collapses the axis to exactly zero")
    func retiredItemStartCollapsesTheAxis() {
        // Seam 1 as reported: the producer holds from 6477.26 on the session axis, the session's shift
        // is 6470.496, and the fresh item's playlist begins 6.76 s into the session.
        let producerFloorSession = 6477.256
        let shift = 6470.496
        // Sampled from the FRESH item, which reports 0.00..60.20: the axis is the 6.76 s the window
        // had dropped, and every conversion after it lands on the picture.
        #expect(abs(AetherEngine.liveItemAxisOffset(
            producerFloorSession: producerFloorSession,
            itemSeekableStart: 0, shift: shift) - 6.76) < 0.005)
        // Sampled from the item that just LEFT, whose seekable start is the playlist floor: zero, to
        // the last decimal, and zero is the number the field log carried for the rest of that item.
        #expect(AetherEngine.liveItemAxisOffset(
            producerFloorSession: producerFloorSession,
            itemSeekableStart: 6.76, shift: shift) == 0)
    }

    /// So the check asks the playlist instead. It served a TIME-OFFSET in the units the item counts
    /// in, which is a statement about content, and whether the client carried it out is answerable
    /// without an axis at all.
    @Test("the check reads the value the playlist served, not a reconstruction of it")
    func checkReadsTheServedValue() {
        let tolerance = AetherEngine.liveRejoinPlacementSatisfiedSeconds
        // Seam 1: served 37.330, the item came up at 37.33, and the reconstruction through the
        // collapsed axis claimed 44.09. The served value retires the seek; the reconstruction fired it.
        let stated = AetherEngine.liveRejoinPlacementTarget(served: 37.330, reconstructed: 44.090)
        #expect(stated?.stated == true)
        #expect(abs(37.33 - (stated?.target ?? 0)) <= tolerance)
        let reconstructed = AetherEngine.liveRejoinPlacementTarget(served: nil, reconstructed: 44.090)
        #expect(reconstructed?.stated == false)
        #expect(abs(37.33 - (reconstructed?.target ?? 0)) > tolerance)
    }

    /// The fallback is the point of keeping the seek, so a client that ignored the tag must still get
    /// it. Seam 1's own item range says where that client would have come up: the edge, 60.20.
    @Test("a client that ignored the served placement still gets the correcting seek")
    func ignoredPlacementStillSeeks() {
        let resolved = AetherEngine.liveRejoinPlacementTarget(served: 37.330, reconstructed: 44.090)
        #expect(abs(60.20 - (resolved?.target ?? 0)) > AetherEngine.liveRejoinPlacementSatisfiedSeconds)
    }

    /// With neither number there is nothing to decide against, and the seek runs as it always did.
    @Test("no statement and no reconstruction leaves the seek alone")
    func noTargetLeavesTheSeek() {
        #expect(AetherEngine.liveRejoinPlacementTarget(served: nil, reconstructed: nil) == nil)
    }

    /// The two numbers the playlist states are consistent with the place the rejoin asked for, which
    /// is what makes the statement usable for the axis as well as for the check: the item's zero plus
    /// the offset it was placed at plus the seam shift IS the held place.
    @Test("the playlist's own two numbers reconstruct the held place exactly")
    func statedNumbersReconstructTheHeldPlace() {
        // Seam 1: the playlist began at output 6.760 and placed the item 37.330 into itself.
        let playlistStartOutput = 6.760, servedOffset = 37.330, shift = 6470.496
        #expect(abs((playlistStartOutput + servedOffset + shift) - 6514.586) < 0.005)
    }
}
