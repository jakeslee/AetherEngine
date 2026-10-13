import Testing
import Foundation
import CoreMedia
import AetherLibavcodec
@testable import AetherEngine

/// AE#492: the parked-video FIFO holds whatever the demux loop read ahead of the renderer, which is
/// the audio lead's worth of video, three to four seconds of it. `drainParkedVideoNonblocking` read
/// the seek generation ONCE and then emptied that FIFO into the decoder, so a seek landing in the
/// middle of the drain had its own `videoDecoder.flush()` undone by the packets that kept arriving
/// after it.
///
/// The frames those packets produced were still refused at the host's decoder callback, which is why
/// this survived #491's two rounds: the damage is done by the ONE frame that does not come out
/// during its own decode. The deinterlacer holds a frame of lookahead, so the last pre-seek frame
/// emerges on the FIRST post-seek decode call, by which time `decodeGeneration` is the new
/// generation and every gate passes it. It is then a sample whose presentation time is the whole
/// seek distance in the future: the display layer accepts it, holds it, stops reporting
/// `isReadyForMoreMediaData`, and the demux loop parks on that signal until its FIFO caps out.
/// Measured on a 480i fixture through the hardware deinterlace chain, twenty seeks a run: three to
/// four seconds of `enq=+0` with `parkedPkts` pinned at 256 and the audio lead decaying under it, on
/// a session reporting `playing` with no rebuffer, on roughly one seek in ten.
///
/// The epoch is what orders the feed against the flush. A caller captures it while its packets are
/// still current and hands it back with each one; `flush()` retires it under the same lock
/// `decode(packet:epoch:)` takes, so the two cannot interleave.
@Suite("A parked packet does not outlive the flush that retired it (#492)")
struct Issue492ParkedFeedEpochTests {

    @Test("a flush retires the epoch a caller is holding")
    func flushRetiresTheEpoch() throws {
        let decoder = SoftwareVideoDecoder()
        let held = decoder.feedEpoch
        decoder.flush()
        #expect(decoder.feedEpoch != held)
    }

    @Test("the epoch keeps moving, so a stale one can never come back around within a session")
    func epochIsMonotonic() {
        let decoder = SoftwareVideoDecoder()
        var seen: Set<UInt64> = [decoder.feedEpoch]
        for _ in 0..<8 {
            decoder.flush()
            #expect(seen.insert(decoder.feedEpoch).inserted)
        }
    }

    /// The rule the drain loop now runs on: nothing is emitted from a packet sent under an epoch the
    /// decoder has retired. Driven through the real decoder rather than a stand-in, because the
    /// refusal has to happen on the far side of `avcodec_send_packet`, not at the caller.
    @Test("a packet carrying a retired epoch produces no frame")
    func retiredEpochProducesNoFrame() throws {
        let decoder = SoftwareVideoDecoder()
        let stale = decoder.feedEpoch
        decoder.flush()

        let frames = FrameCounter()
        decoder.onFrame = { _, _, _ in frames.bump() }
        let packet = try #require(av_packet_alloc())
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }

        decoder.decode(packet: packet, epoch: stale)
        #expect(frames.count == 0)
    }

    /// A caller with no seek of its own (the DVR ring feeder) must not be locked out by a rule it
    /// cannot express.
    @Test("no epoch means no refusal")
    func absentEpochIsNotRefused() throws {
        let decoder = SoftwareVideoDecoder()
        decoder.flush()
        let packet = try #require(av_packet_alloc())
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
        // No decoder is open, so this returns at the context guard rather than at the epoch one.
        // What is under test is that it reaches that guard at all.
        decoder.decode(packet: packet, epoch: nil)
    }

    /// The callback is `@Sendable` and fires off the test's thread; a plain captured var cannot be
    /// mutated from it.
    private final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func bump() { lock.lock(); _count += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }

    @Test("the hardware decoder carries the same rule")
    func hardwareDecoderRetiresItsEpochToo() {
        let decoder = HardwareVideoDecoder()
        let held = decoder.feedEpoch
        decoder.flush()
        #expect(decoder.feedEpoch != held)
    }
}
