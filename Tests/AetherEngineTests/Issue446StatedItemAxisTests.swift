import Foundation
import Testing
@testable import AetherEngine

/// AE#446 round 5: a live item's axis is STATED by the playlist it loads, for every item.
///
/// An item's zero is the first segment its playlist listed (AE#446 round 4), and the build that lists
/// it is the one party that knows that number exactly. The engine reconstructed it instead, as the
/// difference between the cache's resident floor and the item's own reported seekable start, which is
/// only as good as the older of its two samples and is latched for the item's whole life.
///
/// AE#454 round 2 replaced the reconstruction with a statement, but only for an item a rejoin had
/// PLACED, which is an unrelated condition. Everything else stayed on the reconstruction: the
/// session's own first item, the #130 media fallback (documented to run after the window slid), the
/// #35 gate reloads, an AirPlay hop, and the rejoin branch whose target had been evicted.
///
/// The reading that made this measurable came from the field: on 6.57.0 the construction read 0 for
/// an item whose playlist began 6.76 s in.
///
/// AE#446 round 6 retires the other one. The 0.05 s a start item reconstructed on 6.60.0
/// (cmcpherson274, Apple TV 4K gen 3 and the simulator, identical) was published here as a playlist
/// beginning at exactly 0.00 s reading nonzero, and it was not: his first segment really does begin
/// at 0.050 s. A live item's zero is the PRESENTATION time of its first frame while the axis anchor
/// pins the first DECODE time to 0, so on a source with frame reordering every session's first item
/// starts exactly one presentation lead above zero. Measured on the harness, two seeds differing
/// only in that: `lead=3000` (90 kHz) gives `live seg-0 finalized: start=0.033s` and a stated axis of
/// 0.03 s, `-bf 0` gives 0.000 s and 0.00 s. The bundled seed carries no reordering, which is why
/// the harness read 0.00 and the premise survived. What the field reading does show is the branch
/// below it: at the instant of the statement the reconstruction had nothing at all.
@Suite("AE#446 the playlist states every item's axis")
struct Issue446StatedItemAxisTests {

    // MARK: - Helpers

    private func makeLiveProvider(windowSeconds: Double? = nil) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: SegmentCache(forwardWindow: 10, backwardWindow: 10),
            segments: [],
            codecsString: "avc1.640029,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(
                targetSegmentDurationSeconds: 2.0,
                dvrWindowSeconds: windowSeconds
            )
        )
    }

    /// `count` 2 s segments on a 2 s cadence, the shape the harness runs.
    private func fill(_ provider: VideoSegmentProvider, count: Int) {
        for i in 0..<count {
            provider.appendLiveSegment(index: i, startSeconds: Double(i) * 2.0, durationSeconds: 2.0)
        }
    }

    // MARK: - The latch

    @Test("no build has served this item yet, so there is nothing to state")
    func nothingStatedBeforeTheFirstBuild() {
        let provider = makeLiveProvider()
        fill(provider, count: 10)
        #expect(provider.servedLiveItemAxisOutputSeconds == nil)
    }

    @Test("the stated axis is where the listed playlist begins, in seconds")
    func statedAxisIsTheFirstListedSegmentStart() {
        let provider = makeLiveProvider()
        fill(provider, count: 40)
        provider.noteServedLiveItemAxis(firstVisible: 7)
        #expect(provider.servedLiveItemAxisOutputSeconds == 14.0)
    }

    /// An item's zero is the FIRST playlist it loaded. Every later build of a sliding window lists a
    /// higher first segment against the very same content, so a last-build-wins latch would walk the
    /// item's own zero forward underneath it.
    @Test("the first build of an item decides, later builds of a sliding window do not")
    func firstBuildWins() {
        let provider = makeLiveProvider()
        fill(provider, count: 40)
        provider.noteServedLiveItemAxis(firstVisible: 5)
        provider.noteServedLiveItemAxis(firstVisible: 9)
        provider.noteServedLiveItemAxis(firstVisible: 12)
        #expect(provider.servedLiveItemAxisOutputSeconds == 10.0)
    }

    /// The arm is what makes the statement belong to an item rather than to the producer. Without it
    /// the second item of a session would inherit the first one's zero, which is exactly the reading
    /// that put a correctly placed item through a correcting seek on 6.57.0.
    @Test("an attach spends the last item's axis")
    func armClearsTheStatement() {
        let provider = makeLiveProvider()
        fill(provider, count: 40)
        provider.noteServedLiveItemAxis(firstVisible: 5)
        #expect(provider.servedLiveItemAxisOutputSeconds == 10.0)
        provider.armLiveItemAxisStatement()
        #expect(provider.servedLiveItemAxisOutputSeconds == nil)
        provider.noteServedLiveItemAxis(firstVisible: 12)
        #expect(provider.servedLiveItemAxisOutputSeconds == 24.0)
    }

    @Test("an index this producer does not hold states nothing")
    func outOfRangeIndexStatesNothing() {
        let provider = makeLiveProvider()
        fill(provider, count: 10)
        provider.noteServedLiveItemAxis(firstVisible: 99)
        #expect(provider.servedLiveItemAxisOutputSeconds == nil)
        provider.noteServedLiveItemAxis(firstVisible: -1)
        #expect(provider.servedLiveItemAxisOutputSeconds == nil)
    }

    // MARK: - The build states it

    /// The point of round 5: it is the ORDINARY live build that states the axis, not the one that also
    /// happens to carry a rejoin placement.
    @Test("an ordinary live build states the axis it is placing the item on")
    func ordinaryLiveBuildStatesTheAxis() {
        let provider = makeLiveProvider()
        // 2 s cadence, 60 s window -> 30 segments visible, so 35 produced slides to firstVisible 5.
        fill(provider, count: 35)
        provider.armLiveItemAxisStatement()
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        #expect(playlist.contains("#EXT-X-MEDIA-SEQUENCE:5"))
        // The same fact the tag carries by index, in the seconds it stands for.
        #expect(provider.servedLiveItemAxisOutputSeconds == 10.0)
    }

    /// A window whose source has stopped is served as a finished asset (round 2), and an item that
    /// attaches into that window has an axis like any other.
    @Test("a closed outage window still states the axis of the item that loads it")
    func outageBuildStatesTheAxis() {
        let provider = ScriptedAxisProvider(count: 20, firstVisible: 3, outage: true)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        #expect(playlist.contains("#EXT-X-ENDLIST"))
        #expect(provider.statedFirstVisible == [3])
    }

    /// A VOD item's zero is its own zero, so there is nothing to state and nothing to fold.
    @Test("a VOD build states no axis")
    func vodBuildStatesNothing() {
        let provider = ScriptedAxisProvider(count: 20, live: false)
        _ = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        #expect(provider.statedFirstVisible.isEmpty)
    }

    // MARK: - What the reconstruction was missing

    /// AE#446 round 6: the "nothing to say yet" branch is timing, not the item kind, so the line says
    /// which term was absent. cmcpherson274 had to read the source to establish that, which is the
    /// cost this pays off.
    @Test("an item that has not reported its range yet is named as the gap")
    func gapNamesTheItem() {
        #expect(AetherEngine.liveAxisReconstructionGap(
            itemReportsRange: false, hasProducerFloor: true) == "the item reports no seekable range yet")
    }

    @Test("a producer holding nothing yet is named as the gap")
    func gapNamesTheProducer() {
        #expect(AetherEngine.liveAxisReconstructionGap(
            itemReportsRange: true, hasProducerFloor: false) == "the producer holds no resident floor yet")
    }

    @Test("both missing names both, because they are separate signals")
    func gapNamesBoth() {
        let gap = AetherEngine.liveAxisReconstructionGap(itemReportsRange: false, hasProducerFloor: false)
        #expect(gap?.contains("the item reports no seekable range yet") == true)
        #expect(gap?.contains("the producer holds no resident floor yet") == true)
    }

    @Test("nothing missing is not a gap")
    func noGapWhenBothTermsAreThere() {
        #expect(AetherEngine.liveAxisReconstructionGap(
            itemReportsRange: true, hasProducerFloor: true) == nil)
    }

    // MARK: - Which item a statement describes

    @Test("a statement armed by this item's own attach is this item's")
    func statementAppliesToTheArmedItem() {
        #expect(AetherEngine.liveItemAxisStatementApplies(
            armedGeneration: 7, itemGeneration: 7, statedGeneration: -1))
    }

    /// The item that just left armed it; folding its zero into the fresh item's clock is the 6.57.0
    /// reading, 6.76 s away from the picture.
    @Test("a statement armed by the item that just left is not")
    func statementFromTheOutgoingItemIsRefused() {
        #expect(!AetherEngine.liveItemAxisStatementApplies(
            armedGeneration: 6, itemGeneration: 7, statedGeneration: -1))
    }

    @Test("an item that already carries an axis does not take a second one")
    func alreadyStatedItemKeepsItsAxis() {
        #expect(!AetherEngine.liveItemAxisStatementApplies(
            armedGeneration: 7, itemGeneration: 7, statedGeneration: 7))
    }
}

/// Records what the build states, so the question "which builds state an axis at all" can be asked
/// without a producer that has to be talked into an outage.
private final class ScriptedAxisProvider: HLSSegmentProvider, @unchecked Sendable {
    let count: Int
    let first: Int
    let outage: Bool
    let live: Bool
    var refresh = 0
    var statedFirstVisible: [Int] = []

    init(count: Int, firstVisible: Int = 0, outage: Bool = false, live: Bool = true) {
        self.count = count
        self.first = firstVisible
        self.outage = outage
        self.live = live
    }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { count }
    func segmentDuration(at index: Int) -> Double { 2.0 }
    var playlistType: HLSPlaylistType { live ? .live : .vod }
    var liveTargetSegmentDuration: Double? { live ? 2.0 : nil }
    var liveOutageEndlist: Bool { outage }
    func noteServedLiveItemAxis(firstVisible: Int) { statedFirstVisible.append(firstVisible) }
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int,
                                 endlistAdded: Bool, discontinuitySequence: Int) {
        refresh += 1
        return (count, first, refresh, !live, 0)
    }
}
