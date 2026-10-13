import CoreMedia
import CoreVideo
import Foundation

/// An owned decoded buffer selected on the renderer's presentation axis. Retaining this value
/// keeps the buffer alive across seek/stop; neither the renderer nor the consumer may mutate it.
public struct PresentedVideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let generation: UInt64
}

/// Small readback history of buffers actually submitted to the renderer. Selection follows the
/// master clock, never the decode frontier. A slow consumer loses old frames rather than growing
/// a second playback queue. All calls are made under SampleBufferRenderer's reorderLock.
struct PresentedVideoFrameHistory {
    private var frames: [(frame: PresentedVideoFrame, bytes: Int)] = []
    private var bytes = 0
    private let byteLimit = 64 * 1024 * 1024
    private let frameLimit = 32

    mutating func append(_ frame: PresentedVideoFrame) {
        let planeCount = CVPixelBufferGetPlaneCount(frame.pixelBuffer)
        let size = planeCount > 0
            ? (0..<planeCount).reduce(0) { $0 + CVPixelBufferGetBytesPerRowOfPlane(frame.pixelBuffer, $1)
                * CVPixelBufferGetHeightOfPlane(frame.pixelBuffer, $1) }
            : CVPixelBufferGetBytesPerRow(frame.pixelBuffer) * CVPixelBufferGetHeight(frame.pixelBuffer)
        // A single oversized surface cannot fit the history. Reject it without
        // understating its storage or evicting the eligible frames already held.
        guard size > 0, size <= byteLimit else { return }
        frames.append((frame, size))
        bytes += size
        while frames.count > frameLimit || bytes > byteLimit {
            bytes -= frames.removeFirst().bytes
        }
    }

    func frame(at time: CMTime, generation: UInt64) -> PresentedVideoFrame? {
        guard time.isNumeric else { return nil }
        // A future decoded frame has not reached its presentation deadline. Refuse it even
        // during pause/seek rather than labelling it with the caller's current clock.
        guard let candidate = frames.last(where: {
            $0.frame.generation == generation && CMTimeCompare($0.frame.presentationTime, time) <= 0
        })?.frame else { return nil }
        // Do not return an arbitrarily old mask after a stall or a discontinuity.
        return CMTimeSubtract(time, candidate.presentationTime).seconds <= 0.75 ? candidate : nil
    }

    mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        bytes = 0
    }

    var diagnostic: String {
        let latest = frames.last.map { String(format: "%.3f", $0.frame.presentationTime.seconds) } ?? "none"
        return "count=\(frames.count),bytes=\(bytes),latest=\(latest)"
    }
}
