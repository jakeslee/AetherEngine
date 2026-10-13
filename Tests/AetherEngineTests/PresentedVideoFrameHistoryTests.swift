import CoreMedia
import CoreVideo
import Testing
@testable import AetherEngine

@Suite("Presented video frame history", .serialized)
struct PresentedVideoFrameHistoryTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 90_000)
    }

    private func buffer(width: Int = 16, height: Int = 16,
                        format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, format, nil, &result)
        try #require(status == kCVReturnSuccess)
        return try #require(result)
    }

    private func frame(_ buffer: CVPixelBuffer, at seconds: Double,
                       generation: UInt64 = 1) -> PresentedVideoFrame {
        PresentedVideoFrame(pixelBuffer: buffer, presentationTime: time(seconds), generation: generation)
    }

    @Test("Future-only history never supplies a frame, including the old fallback boundary")
    func rejectsFutureFrames() throws {
        var history = PresentedVideoFrameHistory()
        history.append(frame(try buffer(), at: 10))
        for now in [9.25, 9.5, 9.999] {
            #expect(history.frame(at: time(now), generation: 1) == nil)
        }
        #expect(history.frame(at: time(10), generation: 1)?.presentationTime == time(10))
    }

    @Test("Selects the latest eligible past frame even when a future frame is nearer")
    func selectsPastFrame() throws {
        var history = PresentedVideoFrameHistory()
        let image = try buffer()
        for pts in [9.5, 9.75, 10.01] { history.append(frame(image, at: pts)) }
        #expect(history.frame(at: time(10), generation: 1)?.presentationTime == time(9.75))
    }

    @Test("Age is bounded to 750 ms and invalid clocks supply no frame")
    func rejectsStaleAndInvalidTimes() throws {
        var history = PresentedVideoFrameHistory()
        history.append(frame(try buffer(), at: 10))
        #expect(history.frame(at: time(10.75), generation: 1) != nil)
        #expect(history.frame(at: time(10.751), generation: 1) == nil)
        for now in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
            #expect(history.frame(at: now, generation: 1) == nil)
        }
    }

    @Test("A past frame from an old generation cannot justify a future frame from the new one")
    func isolatesGenerations() throws {
        var history = PresentedVideoFrameHistory()
        let image = try buffer()
        history.append(frame(image, at: 10, generation: 1))
        history.append(frame(image, at: 10.25, generation: 2))
        #expect(history.frame(at: time(10), generation: 2) == nil)
        #expect(history.frame(at: time(10.25), generation: 2)?.generation == 2)
        #expect(history.frame(at: time(10.25), generation: 3) == nil)
    }

    @Test("A buffer larger than 64 MiB is rejected without evicting eligible history")
    func rejectsOversizedBuffer() throws {
        var history = PresentedVideoFrameHistory()
        let small = try buffer()
        history.append(frame(small, at: 10))
        let oversized = try buffer(width: 4160, height: 4096)
        try #require(CVPixelBufferGetBytesPerRow(oversized) * CVPixelBufferGetHeight(oversized) > 64 * 1024 * 1024)
        history.append(frame(oversized, at: 10.25))
        let selected = try #require(history.frame(at: time(10.25), generation: 1))
        #expect(selected.pixelBuffer === small)
        #expect(selected.presentationTime == time(10))
    }

    @Test("A buffer exactly at the 64 MiB limit is retained")
    func acceptsExactByteLimit() throws {
        var history = PresentedVideoFrameHistory()
        let image = try buffer(width: 4096, height: 4096)
        try #require(CVPixelBufferGetBytesPerRow(image) * CVPixelBufferGetHeight(image) == 64 * 1024 * 1024)
        history.append(frame(image, at: 10))
        #expect(history.frame(at: time(10), generation: 1)?.pixelBuffer === image)
    }

    @Test("Packed and planar buffers evict old frames using their actual row storage",
          arguments: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    func enforcesByteLimit(format: OSType) throws {
        var history = PresentedVideoFrameHistory()
        for index in 0..<3 {
            // Each buffer is 24 MiB: three fit the frame-count limit but exceed 64 MiB.
            let image = format == kCVPixelFormatType_32BGRA
                ? try buffer(width: 3072, height: 2048, format: format)
                : try buffer(width: 4096, height: 4096, format: format)
            history.append(frame(image, at: 10 + Double(index) / 10))
        }
        #expect(history.frame(at: time(10), generation: 1) == nil)
        #expect(history.frame(at: time(10.1), generation: 1)?.presentationTime == time(10.1))
        #expect(history.frame(at: time(10.2), generation: 1)?.presentationTime == time(10.2))
    }

    @Test("Small buffers are still bounded by 32 frames")
    func enforcesFrameLimit() throws {
        var history = PresentedVideoFrameHistory()
        let image = try buffer()
        for index in 0..<33 { history.append(frame(image, at: Double(index) / 100)) }
        #expect(history.frame(at: time(0), generation: 1) == nil)
        #expect(history.frame(at: time(0.01), generation: 1)?.presentationTime == time(0.01))
    }

    @Test("Reset clears selection and byte accounting while a consumer retains its frame")
    func resetPreservesConsumerOwnership() throws {
        var history = PresentedVideoFrameHistory()
        history.append(frame(try buffer(width: 4096, height: 4096), at: 10))
        let retained = try #require(history.frame(at: time(10), generation: 1))
        history.reset()
        #expect(history.frame(at: time(10), generation: 1) == nil)
        history.append(frame(try buffer(), at: 20, generation: 2))
        #expect(history.frame(at: time(20), generation: 2) != nil)
        #expect(CVPixelBufferGetWidth(retained.pixelBuffer) == 4096)
        #expect(retained.presentationTime == time(10))
    }
}
