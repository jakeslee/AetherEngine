import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AetherLibavutil
import Testing
@testable import AetherEngine

@Suite("HardwareVideoDecoder H.264 framing")
struct HardwareVideoDecoderH264Tests {
    private static let sps = Data([0x67, 0x42, 0x00, 0x1f, 0xe5, 0x88, 0x68])
    private static let pps = Data([0x68, 0xce, 0x06, 0xe2])

    @Test("extracts SPS/PPS from avcC and keeps its input length size")
    func parsesAVCC() {
        let avcC = Data([1, 0x42, 0, 0x1f, 0xff, 1, 0, 7]) + Self.sps + Data([1, 0, 4]) + Self.pps
        #expect(HardwareVideoDecoder.h264NALLength(from: avcC) == 4)
        #expect(HardwareVideoDecoder.h264ParameterSets(from: avcC) == [Self.sps, Self.pps])
    }

    @Test("extracts SPS/PPS from Annex-B CodecPrivate")
    func parsesAnnexB() {
        let annexB = Data([0, 0, 0, 1]) + Self.sps + Data([0, 0, 1]) + Self.pps
        #expect(HardwareVideoDecoder.h264ParameterSets(from: annexB) == [Self.sps, Self.pps])
    }

    @Test("normalizes Annex-B access units to four-byte lengths")
    func normalizesAnnexBPacket() {
        let packet = Data([0, 0, 1, 0x65, 1, 2, 3, 0, 0, 0, 1, 0x41, 4, 5])
        let normalized = HardwareVideoDecoder.normalizeH264Packet(packet, annexB: true, inputNALLength: 4)
        #expect(Array(normalized) == [0, 0, 0, 4, 0x65, 1, 2, 3, 0, 0, 0, 3, 0x41, 4, 5])
    }

    @Test("normalizes two-byte avcC access units")
    func normalizesShortLengths() {
        let packet = Data([0, 3, 0x65, 1, 2, 0, 2, 0x41, 3])
        let normalized = HardwareVideoDecoder.normalizeH264Packet(packet, annexB: false, inputNALLength: 2)
        #expect(Array(normalized) == [0, 0, 0, 3, 0x65, 1, 2, 0, 0, 0, 2, 0x41, 3])
    }

    @Test("all SPS and PPS reach CoreMedia, including a PPS referring to the second SPS")
    func multipleParameterSets() throws {
        let sps0 = Self.baselineSPS(id: 0)
        let sps1 = Self.baselineSPS(id: 1)
        let pps0 = Self.baselinePPS(id: 0)
        let pps1 = Self.baselinePPS(id: 1)
        let sets = [sps0, sps1, pps0, pps1]
        var avcC = Data([1, 66, 0, 30, 0xff, 0xe2])
        for sps in [sps0, sps1] { avcC += Self.lengthPrefixed(sps) }
        avcC.append(2)
        for pps in [pps0, pps1] { avcC += Self.lengthPrefixed(pps) }
        let annexB = sets.reduce(into: Data()) { $0 += Data([0, 0, 0, 1]) + $1 }
        for extradata in [avcC, annexB] {
            let parsed = HardwareVideoDecoder.h264ParameterSets(from: extradata)
            #expect(parsed == sets)
            let description = try HardwareVideoDecoder.h264FormatDescription(parameterSets: parsed)
            var recovered: [Data] = []
            for index in sets.indices {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                var nalLength: Int32 = 0
                #expect(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &nalLength) == noErr)
                #expect(count == sets.count)
                #expect(nalLength == 4)
                recovered.append(Data(bytes: try #require(pointer), count: size))
            }
            #expect(recovered == sets)
        }
    }

    @Test("SPS-only and truncated avcC cannot masquerade as a complete configuration")
    func rejectsIncompleteParameterSets() {
        #expect(throws: VideoDecoderError.self) {
            try HardwareVideoDecoder.h264FormatDescription(parameterSets: [Self.sps, Self.sps])
        }
        #expect(throws: VideoDecoderError.self) {
            try HardwareVideoDecoder.h264FormatDescription(parameterSets: [Self.pps])
        }
        let missingPPS = Data([1, 66, 0, 30, 0xff, 1]) + Self.lengthPrefixed(Self.sps)
        #expect(HardwareVideoDecoder.h264ParameterSets(from: missingPPS).isEmpty)
        let truncatedPPS = missingPPS + Data([1, 0, 4, 0x68])
        #expect(HardwareVideoDecoder.h264ParameterSets(from: truncatedPPS).isEmpty)
    }

    @Test("8/10-bit full/video range are independent of HDR transfer")
    func outputRangesAndDepth() {
        for (depth, full, video) in [
            (Int32(8), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (Int32(10), kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
        ] {
            for (range, expected) in [(AVCOL_RANGE_JPEG, full), (AVCOL_RANGE_MPEG, video), (AVCOL_RANGE_UNSPECIFIED, video)] {
                #expect(HardwareVideoDecoder.outputPixelFormat(
                    bitsPerSample: depth, sourceFormat: AV_PIX_FMT_NONE,
                    transfer: AVCOL_TRC_BT709, range: range) == expected)
            }
        }
        #expect(HardwareVideoDecoder.outputPixelFormat(
            bitsPerSample: 0, sourceFormat: AV_PIX_FMT_YUV420P10LE,
            transfer: AVCOL_TRC_BT709, range: AVCOL_RANGE_JPEG) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        #expect(HardwareVideoDecoder.outputPixelFormat(
            bitsPerSample: 0, sourceFormat: AV_PIX_FMT_NONE,
            transfer: AVCOL_TRC_SMPTE2084, range: AVCOL_RANGE_MPEG) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    }

    @Test("CMBlockBuffer owns a copy after source storage is changed and released")
    func blockBufferOwnership() throws {
        let expected = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        let buffer: CMBlockBuffer = try autoreleasepool {
            var source = expected
            let buffer = try #require(HardwareVideoDecoder.copiedBlockBuffer(source))
            source.resetBytes(in: 0..<source.count)
            return buffer
        }
        var actual = Data(count: expected.count)
        let status = actual.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        #expect(status == noErr)
        #expect(actual == expected)
        #expect(HardwareVideoDecoder.copiedBlockBuffer(Data()) == nil)
    }

    @Test("late pre-flush callbacks cannot deliver or clear the new seek threshold")
    func staleOutputAfterFlush() throws {
        let decoder = HardwareVideoDecoder()
        let buffer = try Self.pixelBuffer()
        let stale = decoder.outputHandler(for: decoder.feedEpoch)
        decoder.flush()
        let threshold = CMTime(value: 50, timescale: 1)
        decoder.skipUntilPTS = threshold
        let delivered = DispatchSemaphore(value: 0)
        let frames = FrameLog()
        decoder.onFrame = { _, pts, _ in frames.append(pts); delivered.signal() }
        // A stale PTS beyond the new threshold must not clear it. The following current
        // pre-roll frame is rejected only if that threshold was preserved.
        stale(noErr, [], buffer, CMTime(value: 100, timescale: 1), .invalid)
        let current = decoder.outputHandler(for: decoder.feedEpoch)
        current(noErr, [], buffer, CMTime(value: 40, timescale: 1), .invalid)
        current(noErr, [], buffer, threshold, .invalid)
        #expect(delivered.wait(timeout: .now() + 2) == .success)
        #expect(frames.values == [threshold])
        #expect(decoder.skipUntilPTS == nil)
    }

    @Test("close invalidates pending output even after a replacement handler is installed")
    func staleOutputAfterClose() throws {
        let decoder = HardwareVideoDecoder()
        let buffer = try Self.pixelBuffer()
        let epoch = decoder.feedEpoch
        let oldOutput = decoder.outputHandler(for: epoch)
        decoder.close()
        #expect(decoder.feedEpoch != epoch)
        #expect(decoder.hardwareAccelerationActive == nil)
        let delivered = DispatchSemaphore(value: 0)
        let frames = FrameLog()
        decoder.onFrame = { _, pts, _ in frames.append(pts); delivered.signal() }
        oldOutput(noErr, [], buffer, CMTime(value: 1, timescale: 1), .invalid)
        decoder.outputHandler(for: decoder.feedEpoch)(noErr, [], buffer, CMTime(value: 2, timescale: 1), .invalid)
        #expect(delivered.wait(timeout: .now() + 2) == .success)
        #expect(frames.values == [CMTime(value: 2, timescale: 1)])
    }

    @Test("error, dropped and nil-image callbacks do not deliver")
    func failedOutput() throws {
        let decoder = HardwareVideoDecoder()
        let output = decoder.outputHandler(for: decoder.feedEpoch)
        let buffer = try Self.pixelBuffer()
        let delivered = DispatchSemaphore(value: 0)
        let frames = FrameLog()
        decoder.onFrame = { _, pts, _ in frames.append(pts); delivered.signal() }
        output(-1, [], buffer, .zero, .invalid)
        output(noErr, [.frameDropped], buffer, .zero, .invalid)
        output(noErr, [], nil, .zero, .invalid)
        output(noErr, [], buffer, CMTime(value: 1, timescale: 1), .invalid)
        #expect(delivered.wait(timeout: .now() + 2) == .success)
        #expect(frames.values == [CMTime(value: 1, timescale: 1)])
    }

    @Test("delivery can read epoch, flush and close reentrantly")
    func reentrantLifecycle() throws {
        let decoder = HardwareVideoDecoder()
        let output = decoder.outputHandler(for: decoder.feedEpoch)
        let finished = DispatchSemaphore(value: 0)
        decoder.onFrame = { [weak decoder] _, _, _ in
            guard let decoder else { return }
            let epoch = decoder.feedEpoch
            decoder.flush()
            #expect(decoder.feedEpoch != epoch)
            decoder.close()
            finished.signal()
        }
        output(noErr, [], try Self.pixelBuffer(), .zero, .invalid)
        #expect(finished.wait(timeout: .now() + 2) == .success)
    }

    @Test("an outstanding VT handler does not retain its decoder")
    func outputHandlerLifetime() throws {
        var decoder: HardwareVideoDecoder? = HardwareVideoDecoder()
        weak var weakDecoder = decoder
        let output = try #require(decoder).outputHandler(for: 0)
        decoder = nil
        #expect(weakDecoder == nil)
        output(noErr, [], try Self.pixelBuffer(), .zero, .invalid)
    }

    private final class FrameLog: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [CMTime] = []
        var values: [CMTime] { lock.lock(); defer { lock.unlock() }; return frames }
        func append(_ pts: CMTime) { lock.lock(); frames.append(pts); lock.unlock() }
    }

    private static func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    nil, &buffer) == kCVReturnSuccess)
        return try #require(buffer)
    }

    private static func lengthPrefixed(_ data: Data) -> Data {
        Data([UInt8(data.count >> 8), UInt8(data.count & 0xff)]) + data
    }

    // Minimal baseline SPS/PPS with distinct IDs, 640x480, no VUI or cropping.
    private static func ue(_ value: Int) -> String {
        let bits = String(value + 1, radix: 2)
        return String(repeating: "0", count: bits.count - 1) + bits
    }

    private static func rbsp(_ bits: String) -> Data {
        var bits = bits + "1"
        bits += String(repeating: "0", count: (8 - bits.count % 8) % 8)
        let chars = Array(bits)
        return Data(stride(from: 0, to: chars.count, by: 8).map {
            UInt8(String(chars[$0..<($0 + 8)]), radix: 2)!
        })
    }

    private static func baselineSPS(id: Int) -> Data {
        Data([0x67, 66, 0, 30]) + rbsp(ue(id) + ue(0) + ue(0) + ue(0) + ue(1)
                                      + "0" + ue(39) + ue(29) + "1100")
    }

    private static func baselinePPS(id: Int) -> Data {
        Data([0x68]) + rbsp(ue(id) + ue(id) + "00" + ue(0) + ue(0) + ue(0)
                            + "000" + ue(0) + ue(0) + ue(0) + "100")
    }
}
