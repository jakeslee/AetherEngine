import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

struct ColorDescriptionTests {

    private let pq = ColorDescription(
        primaries: AVCOL_PRI_BT2020, transfer: AVCOL_TRC_SMPTE2084,
        matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_MPEG)

    @Test("AE#499: a bitstream that describes itself is never overruled by the container")
    func bitstreamWins() {
        let container = ColorDescription(
            primaries: AVCOL_PRI_BT709, transfer: AVCOL_TRC_BT709,
            matrix: AVCOL_SPC_BT709, range: AVCOL_RANGE_JPEG)
        #expect(ColorDescription.resolved(bitstream: pq, container: container) == pq)
    }

    @Test("AE#499: an empty VUI takes the container's description rather than staying unspecified")
    func containerFillsAnEmptyVUI() {
        #expect(ColorDescription.resolved(bitstream: .unspecified, container: pq) == pq)
    }

    @Test("AE#499: the fields resolve one by one, which is the case that reached the tone mapper")
    func fieldsResolveIndependently() {
        // The reported frame carried a matrix and a range and no transfer: enough for the extractor's
        // HDR gate to read PQ off the stream, not enough for zscale to find a path to linear.
        let partial = ColorDescription(
            primaries: AVCOL_PRI_UNSPECIFIED, transfer: AVCOL_TRC_UNSPECIFIED,
            matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_MPEG)
        #expect(ColorDescription.resolved(bitstream: partial, container: pq) == pq)

        let containerSaysHLG = ColorDescription(
            primaries: AVCOL_PRI_BT2020, transfer: AVCOL_TRC_ARIB_STD_B67,
            matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_MPEG)
        let bitstreamSaysPQ = ColorDescription(
            primaries: AVCOL_PRI_UNSPECIFIED, transfer: AVCOL_TRC_SMPTE2084,
            matrix: AVCOL_SPC_UNSPECIFIED, range: AVCOL_RANGE_UNSPECIFIED)
        let mixed = ColorDescription.resolved(bitstream: bitstreamSaysPQ, container: containerSaysHLG)
        #expect(mixed.transfer == AVCOL_TRC_SMPTE2084)
        #expect(mixed.primaries == AVCOL_PRI_BT2020)
        #expect(mixed.matrix == AVCOL_SPC_BT2020_NCL)
        #expect(mixed.range == AVCOL_RANGE_MPEG)
    }

    @Test("AE#499: two silences stay silent, so nothing is invented for an untagged stream")
    func nothingIsInvented() {
        #expect(ColorDescription.resolved(bitstream: .unspecified, container: .unspecified) == .unspecified)
    }

    @Test("AE#499: backfilling writes the resolved description onto the frame, once")
    func backfillWritesTheFrame() throws {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        let f = try #require(frame)
        defer { av_frame_free(&frame) }
        f.pointee.color_primaries = AVCOL_PRI_UNSPECIFIED
        f.pointee.color_trc = AVCOL_TRC_UNSPECIFIED
        f.pointee.colorspace = AVCOL_SPC_BT2020_NCL
        f.pointee.color_range = AVCOL_RANGE_MPEG

        #expect(ColorDescription.backfill(frame: f, container: pq) == true)
        #expect(ColorDescription(frame: f) == pq)
        // Idempotent: the second pass has nothing left to fill and says so.
        #expect(ColorDescription.backfill(frame: f, container: pq) == false)
    }

    @Test("AE#499: a container with nothing to say leaves the frame alone")
    func silentContainerChangesNothing() throws {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        let f = try #require(frame)
        defer { av_frame_free(&frame) }
        f.pointee.color_primaries = AVCOL_PRI_UNSPECIFIED
        f.pointee.color_trc = AVCOL_TRC_UNSPECIFIED
        f.pointee.colorspace = AVCOL_SPC_UNSPECIFIED
        f.pointee.color_range = AVCOL_RANGE_UNSPECIFIED

        #expect(ColorDescription.backfill(frame: f, container: .unspecified) == false)
        #expect(ColorDescription(frame: f) == .unspecified)
    }
}
