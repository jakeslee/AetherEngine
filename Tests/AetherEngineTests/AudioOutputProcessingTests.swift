import XCTest
import AVFoundation
import CoreMedia
@testable import AetherEngine

final class AudioOutputProcessingTests: XCTestCase {
    func testProcessorPrimesRendererBeforeClockStarts() throws {
        let output = AudioOutput()
        defer { output.stop() }
        let processed = expectation(description: "PCM submitted while clock is paused")
        let restarted = expectation(description: "PCM primed after seek flush")
        output.sampleProcessor = { buffer, startsStream in
            XCTAssertTrue(startsStream)
            if CMSampleBufferGetPresentationTimeStamp(buffer) == .zero {
                processed.fulfill()
            } else {
                restarted.fulfill()
            }
        }
        output.enqueue(sampleBuffer: try sample())
        wait(for: [processed], timeout: 2)
        XCTAssertEqual(output.rate, 0)
        XCTAssertNil(output.renderer.error)

        // A seek flush must reset DSP and prime again even before playback resumes.
        output.flush()
        output.enqueue(sampleBuffer: try sample(at: CMTime(seconds: 10, preferredTimescale: 48_000)))
        wait(for: [restarted], timeout: 2)
        XCTAssertEqual(output.rate, 0)
        XCTAssertNil(output.renderer.error)
    }

    private func sample(at time: CMTime = .zero) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
            blockLength: 1024 * 8, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: 1024 * 8, flags: 0, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0,
            dataLength: 1024 * 8), noErr)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil,
            dataBuffer: data, formatDescription: try XCTUnwrap(format), sampleCount: 1024,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &buffer), noErr)
        return try XCTUnwrap(buffer)
    }
}
