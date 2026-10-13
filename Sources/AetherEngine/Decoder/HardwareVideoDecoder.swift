import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// VTDecompressionSession-backed H.264/HEVC decoder for the SoftwarePlaybackHost pipeline.
/// Owns the decoded-frame pool, IOSurface lifetime, and session teardown explicitly
/// (AVPlayer's opaque state grows unbounded on long 4K HDR sessions).
/// Same surface as SoftwareVideoDecoder so the host can swap without rewiring the demux loop.
final class HardwareVideoDecoder: VideoDecodingPipeline, @unchecked Sendable {

    // MARK: - Public surface (mirrors SoftwareVideoDecoder)

    /// Multi-word closure swaps are guarded independently of session operations.
    var onFrame: DecodedFrameHandler? {
        get { skipLock.lock(); defer { skipLock.unlock() }; return _onFrame }
        set { skipLock.lock(); _onFrame = newValue; skipLock.unlock() }
    }
    private var _onFrame: DecodedFrameHandler?
    /// Not yet wired on the VT side (follow-up: read AV_PKT_DATA_DYNAMIC_HDR10_PLUS before decode,
    /// mirror SoftwareVideoDecoder.extractHDR10PlusBytes). Flag kept so host wiring stays identical to SW path.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?

    /// Skip pre-seek RASL frames to avoid the "fast forward" effect; decoded for reference but not delivered.
    /// CMTime is multi-word, so reads and compare-and-clear must share a lock.
    var skipUntilPTS: CMTime? {
        get { skipLock.lock(); defer { skipLock.unlock() }; return _skipUntilPTS }
        set { skipLock.lock(); _skipUntilPTS = newValue; skipLock.unlock() }
    }
    private var _skipUntilPTS: CMTime?
    private let skipLock = NSLock()

    /// Clear the skip threshold only if it is still the one we acted on.
    private func clearSkip(ifStillAt threshold: CMTime) {
        skipLock.lock()
        if let current = _skipUntilPTS, CMTimeCompare(current, threshold) == 0 {
            _skipUntilPTS = nil
        }
        skipLock.unlock()
    }

    // MARK: - Internals

    private var session: VTDecompressionSession?
    /// Read the actual playback session, not a throwaway capability probe.
    var hardwareAccelerationActive: Bool? {
        lock.lock(); defer { lock.unlock() }
        guard let session else { return nil }
        var value: Unmanaged<CFTypeRef>?
        guard VTSessionCopyProperty(session,
                                    key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                    allocator: kCFAllocatorDefault, valueOut: &value) == noErr else { return nil }
        return (value?.takeRetainedValue() as? NSNumber)?.boolValue
    }
    private var formatDescription: CMVideoFormatDescription?
    private var codecID: AVCodecID = AV_CODEC_ID_NONE
    /// H.264 sources may carry Annex-B packets or an avcC length-prefixed packet stream. VT's
    /// sample format is normalized to four-byte lengths, so the decoder records the source shape
    /// and converts only when required.
    private var h264AnnexB = false
    private var h264InputNALLength = 4
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)
    private var width: Int32 = 0
    private var height: Int32 = 0

    /// Color metadata from codecpar, re-applied to every CVPixelBuffer.
    /// VTDecompressionSession should propagate these from SPS+hvcC but has been observed not to;
    /// without them an HDR buffer renders as desaturated SDR on AVSampleBufferDisplayLayer.
    private var colorPrimaries: CFString?
    private var colorTransfer: CFString?
    private var colorMatrix: CFString?

    /// #354: the stream's pixel aspect ratio, re-applied to every CVPixelBuffer for the same reason
    /// the colorimetry is: nothing else puts it there. The renderer builds its format description
    /// from the delivered buffer, so a ratio that is not an attachment on that buffer never reaches
    /// the layer, and anamorphic content is displayed at its coded dimensions. nil for square pixels
    /// and for a ratio the policy rejects, which is the case where coded dimensions ARE correct.
    ///
    /// Resolved once at `open()`, not per frame: VT delivers pixel buffers rather than `AVFrame`s, so
    /// the per-frame source `SoftwareVideoDecoder` prefers does not exist here. That also makes the
    /// #177 latch unnecessary, since one resolution cannot oscillate.
    private var pixelAspectRatio: AVRational?

    /// Serializes submission, session lifecycle and delivery, including the final onFrame call.
    /// Recursive because a consumer may read feedEpoch or flush/close from onFrame.
    /// VT callbacks ONLY enqueue onto deliveryQueue, never acquire this lock or call consumers:
    /// a synchronous decode callback or a drain under this lock therefore cannot deadlock.
    private let lock = NSRecursiveLock()
    private let deliveryQueue = DispatchQueue(label: "AetherEngine.HardwareVideoDecoder.delivery")

    /// AE#492: guarded by `lock`, the same one `flush()` and `decode(packet:epoch:)` take.
    private var _feedEpoch: UInt64 = 0
    var feedEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }; return _feedEpoch
    }

    // MARK: - Lifecycle

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        lock.lock()
        defer { lock.unlock() }
        close()
        self.onFrame = onFrame

        guard let codecpar = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base
        width = codecpar.pointee.width
        height = codecpar.pointee.height

        // #354: both declared sources, because only one of them is the container's. The bitstream
        // ratio reaches codecpar, while a container-declared one reaches AVStream alone (Matroska's
        // DisplayWidth quotient, MP4's `pasp`), which is where every DVD remuxed to MKV carries it.
        pixelAspectRatio = Self.resolvePixelAspectRatio(
            bitstream: codecpar.pointee.sample_aspect_ratio,
            container: stream.pointee.sample_aspect_ratio,
            width: width,
            height: height
        )
        if let sar = pixelAspectRatio {
            EngineLog.emit(
                "[HWDecoder] SAR \(sar.num):\(sar.den) on \(width)x\(height) "
                + "(bitstream=\(codecpar.pointee.sample_aspect_ratio.num):"
                + "\(codecpar.pointee.sample_aspect_ratio.den) "
                + "container=\(stream.pointee.sample_aspect_ratio.num):"
                + "\(stream.pointee.sample_aspect_ratio.den))",
                category: .swPlayback
            )
        }

        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC || codecpar.pointee.codec_id == AV_CODEC_ID_H264 else {
            throw VideoDecoderError.unsupportedCodec(id: codecpar.pointee.codec_id.rawValue)
        }
        codecID = codecpar.pointee.codec_id

        // 1. Build CMVideoFormatDescription from the codec extradata. H.264 uses the parameter-set
        // API so both avcC and Annex-B CodecPrivate are accepted; HEVC keeps the atom path used by
        // the existing decoder.
        guard let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 else {
            throw VideoDecoderError.noExtradata
        }
        var fd: CMVideoFormatDescription?
        let extradataBytes = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
        let fdStatus: OSStatus
        if codecID == AV_CODEC_ID_H264 {
            let parameterSets = Self.h264ParameterSets(from: extradataBytes)
            h264AnnexB = extradataBytes.first != 1
            h264InputNALLength = Self.h264NALLength(from: extradataBytes)
            fd = try Self.h264FormatDescription(parameterSets: parameterSets)
            fdStatus = noErr
        } else {
            let atomsDict: NSDictionary = ["hvcC": extradataBytes]
            let extensions: NSDictionary = [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atomsDict,
            ]
            fdStatus = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_HEVC,
                width: width,
                height: height,
                extensions: extensions,
                formatDescriptionOut: &fd
            )
        }
        guard fdStatus == noErr, let formatDesc = fd else {
            throw VideoDecoderError.formatDescriptionFailed(status: fdStatus)
        }
        formatDescription = formatDesc

        // 2. Require hardware so VT fails outright rather than silently falling back to SW
        //    (which would show only as pathological CPU + frame drops at 4K).
        let decoderSpec: NSDictionary = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]

        // 3. Pixel buffer attributes: 10-bit biplanar for HDR, 8-bit for SDR; IOSurface-backed for Metal rendering.
        self.colorPrimaries = ColorAttachments.primaries(codecpar.pointee.color_primaries)
        self.colorTransfer = ColorAttachments.transfer(codecpar.pointee.color_trc)
        self.colorMatrix = ColorAttachments.matrix(codecpar.pointee.color_space)
        let pixelFormat = Self.outputPixelFormat(
            bitsPerSample: codecpar.pointee.bits_per_raw_sample,
            sourceFormat: AVPixelFormat(rawValue: codecpar.pointee.format),
            transfer: codecpar.pointee.color_trc,
            range: codecpar.pointee.color_range
        )

        let pixelBufferAttrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        // 4. Each decode supplies its own ARC-managed output handler and immutable epoch.
        var sessionOut: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpec,
            imageBufferAttributes: pixelBufferAttrs,
            outputCallback: nil,
            decompressionSessionOut: &sessionOut
        )
        guard status == noErr, let createdSession = sessionOut else {
            throw VideoDecoderError.sessionCreationFailed(status: status)
        }
        session = createdSession

        // 5. Pass through per-frame HDR metadata for correct tone mapping; unknown-key set returns -12911 on older OSes (swallowed).
        VTSessionSetProperty(
            createdSession,
            key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
            value: kCFBooleanTrue
        )

        EngineLog.emit(
            "[HardwareVideoDecoder] opened \(codecID == AV_CODEC_ID_H264 ? "H.264" : "HEVC") \(width)x\(height) "
            + "pixelFormat=\(pixelFormat) "
            + "transfer=\(codecpar.pointee.color_trc.rawValue)",
            category: .swPlayback
        )
    }

    // MARK: - Decode

    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        // AE#492: see `SoftwareVideoDecoder.decode`. Same rule, same lock as `flush()`.
        if let epoch, epoch != _feedEpoch { return }
        guard let session = session, let formatDesc = formatDescription else {
            return
        }
        let frameEpoch = _feedEpoch

        // Normalize H.264 Annex-B or non-four-byte length prefixes before wrapping. HEVC packets
        // already use the length-prefix framing produced by the demuxer.
        // in a CMBlockBuffer+CMSampleBuffer. Copy once: VT may retain the buffer past the call (async decode),
        // and AVPacket storage is reused for the next packet.
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        let sourceData = Data(bytes: data, count: Int(packet.pointee.size))
        let normalizedData: Data
        if codecID == AV_CODEC_ID_H264 {
            normalizedData = Self.normalizeH264Packet(sourceData, annexB: h264AnnexB,
                                                      inputNALLength: h264InputNALLength)
        } else {
            normalizedData = sourceData
        }
        guard !normalizedData.isEmpty else { return }
        let size = normalizedData.count
        guard let bb = Self.copiedBlockBuffer(normalizedData) else { return }
        let ptsRaw = packet.pointee.pts
        let dtsRaw = packet.pointee.dts
        let durRaw = packet.pointee.duration
        let timescale = max(timeBase.den, 1)

        let pts = (ptsRaw != Int64.min)
            ? CMTimeMake(value: ptsRaw * Int64(timeBase.num), timescale: timescale)
            : CMTime.invalid
        let dts = (dtsRaw != Int64.min)
            ? CMTimeMake(value: dtsRaw * Int64(timeBase.num), timescale: timescale)
            : CMTime.invalid
        let dur = (durRaw > 0)
            ? CMTimeMake(value: durRaw * Int64(timeBase.num), timescale: timescale)
            : CMTime.invalid

        var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var sampleSize = size

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else { return }

        // Tag non-keyframes as DependsOnOthers so VT can drop pre-seek RASL frames after a flush.
        if (packet.pointee.flags & AV_PKT_FLAG_KEY) == 0 {
            if let attachArray = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
               CFArrayGetCount(attachArray) > 0 {
                let dict = unsafeBitCast(
                    CFArrayGetValueAtIndex(attachArray, 0),
                    to: CFMutableDictionary.self
                )
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        // Hold the submission lock through the VT call so close/flush cannot overtake a packet
        // that already passed the epoch check. The output handler never takes this lock.
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            infoFlagsOut: &infoFlags, outputHandler: outputHandler(for: frameEpoch)
        )
        if decodeStatus != noErr {
            EngineLog.emit(
                "[HardwareVideoDecoder] decode error \(decodeStatus) at pts=\(ptsRaw)",
                category: .swPlayback
            )
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        _feedEpoch &+= 1   // AE#492
        guard let session else { return }
        // Wait also finishes delayed frames. It does not reset the reference picture state;
        // seek resumes at a random-access packet. Queued output is rejected by its old epoch.
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        _feedEpoch &+= 1
        onFrame = nil
        skipUntilPTS = nil
        if let session = session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        formatDescription = nil
    }

    deinit {
        close()
    }

    // MARK: - Sample storage and output format

    /// Let CoreMedia both allocate and free the backing storage. Swift allocate/deallocate
    /// must not be mixed with CFAllocator's deallocator when an async sample owns the bytes.
    static func copiedBlockBuffer(_ data: Data) -> CMBlockBuffer? {
        guard !data.isEmpty else { return nil }
        var buffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0,
            blockBufferOut: &buffer
        ) == kCMBlockBufferNoErr, let buffer else { return nil }
        let status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: buffer,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        return status == kCMBlockBufferNoErr ? buffer : nil
    }

    static func outputPixelFormat(
        bitsPerSample: Int32, sourceFormat: AVPixelFormat,
        transfer: AVColorTransferCharacteristic, range: AVColorRange
    ) -> OSType {
        // codecpar.bits_per_raw_sample is often zero for HEVC Main10 SDR; the pixel-format
        // descriptor still carries its depth. HDR transfer is a fallback, not a range flag.
        let formatDepth = av_pix_fmt_desc_get(sourceFormat)?.pointee.comp.0.depth ?? 0
        let use10Bit = max(bitsPerSample, formatDepth) > 8 || ColorAttachments.isHDRTransfer(transfer)
        if use10Bit {
            return range == AVCOL_RANGE_JPEG
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        return range == AVCOL_RANGE_JPEG
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    // MARK: - H.264 framing

    static func h264FormatDescription(parameterSets: [Data]) throws -> CMVideoFormatDescription {
        guard parameterSets.contains(where: { $0.first.map { $0 & 0x1F == 7 } == true }),
              parameterSets.contains(where: { $0.first.map { $0 & 0x1F == 8 } == true }),
              parameterSets.allSatisfy({ !$0.isEmpty }) else {
            throw VideoDecoderError.noExtradata
        }
        // One contiguous allocation keeps ALL SPS/PPS pointers alive for the entire CM call,
        // including small Data values whose withUnsafeBytes pointer would otherwise expire.
        let storage = parameterSets.reduce(into: Data()) { $0.append($1) }
        let sizes = parameterSets.map(\.count)
        var description: CMVideoFormatDescription?
        let status = storage.withUnsafeBytes { bytes in
            let base = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var offset = 0
            let pointers = sizes.map { size -> UnsafePointer<UInt8> in
                defer { offset += size }
                return base.advanced(by: offset)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw VideoDecoderError.formatDescriptionFailed(status: status)
        }
        return description
    }

    static func h264NALLength(from extradata: Data) -> Int {
        guard extradata.first == 1, extradata.count > 4 else { return 4 }
        return [1, 2, 4].contains(Int(extradata[4] & 0x03) + 1)
            ? Int(extradata[4] & 0x03) + 1 : 4
    }

    static func h264ParameterSets(from extradata: Data) -> [Data] {
        if extradata.first == 1 {
            var sets: [Data] = []
            var cursor = 5
            guard cursor < extradata.count else { return [] }
            let spsCount = Int(extradata[cursor] & 0x1F); cursor += 1
            for _ in 0..<spsCount {
                guard cursor + 2 <= extradata.count else { return [] }
                let length = Int(extradata[cursor]) << 8 | Int(extradata[cursor + 1]); cursor += 2
                guard length > 0, cursor + length <= extradata.count else { return [] }
                sets.append(extradata.subdata(in: cursor..<(cursor + length))); cursor += length
            }
            guard cursor < extradata.count else { return [] }
            let ppsCount = Int(extradata[cursor]); cursor += 1
            for _ in 0..<ppsCount {
                guard cursor + 2 <= extradata.count else { return [] }
                let length = Int(extradata[cursor]) << 8 | Int(extradata[cursor + 1]); cursor += 2
                guard length > 0, cursor + length <= extradata.count else { return [] }
                sets.append(extradata.subdata(in: cursor..<(cursor + length))); cursor += length
            }
            return sets
        }
        let bytes = [UInt8](extradata)
        var sets: [Data] = []
        var i = 0
        while i + 3 < bytes.count {
            let start: Int?
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 { start = i + 3 }
            else if i + 4 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 { start = i + 4 }
            else { i += 1; continue }
            guard let start else { break }
            var end = start
            while end < bytes.count {
                if end + 2 < bytes.count, bytes[end] == 0, bytes[end + 1] == 0,
                   bytes[end + 2] == 1 { break }
                if end + 3 < bytes.count, bytes[end] == 0, bytes[end + 1] == 0,
                   bytes[end + 2] == 0, bytes[end + 3] == 1 { break }
                end += 1
            }
            if start < end, (bytes[start] & 0x1F == 7 || bytes[start] & 0x1F == 8) {
                sets.append(Data(bytes[start..<end]))
            }
            i = end
        }
        return sets
    }

    static func normalizeH264Packet(_ data: Data, annexB: Bool, inputNALLength: Int) -> Data {
        let bytes = [UInt8](data)
        var nals: [ArraySlice<UInt8>] = []
        if annexB {
            var i = 0
            while i + 3 < bytes.count {
                let start: Int
                if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 { start = i + 3 }
                else if i + 4 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 { start = i + 4 }
                else { i += 1; continue }
                var end = start
                while end < bytes.count {
                    if end + 2 < bytes.count, bytes[end] == 0, bytes[end + 1] == 0,
                       bytes[end + 2] == 1 { break }
                    if end + 3 < bytes.count, bytes[end] == 0, bytes[end + 1] == 0,
                       bytes[end + 2] == 0, bytes[end + 3] == 1 { break }
                    end += 1
                }
                if start < end { nals.append(bytes[start..<end]) }
                i = end
            }
        } else {
            var cursor = 0
            while cursor + inputNALLength <= bytes.count {
                var length = 0
                for _ in 0..<inputNALLength { length = (length << 8) | Int(bytes[cursor]); cursor += 1 }
                guard length > 0, cursor + length <= bytes.count else { return data }
                nals.append(bytes[cursor..<(cursor + length)]); cursor += length
            }
        }
        guard !nals.isEmpty else { return data }
        var output = Data(); output.reserveCapacity(bytes.count + nals.count * (4 - inputNALLength))
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(contentsOf: nal)
        }
        return output
    }

    /// The ratio to attach, or nil when there is nothing to correct. Bitstream first, container
    /// second (`declaredStreamSAR`), then the same two gates the libavcodec path runs: the #177
    /// component bound and the #290 display aspect the ratio produces on this frame. Square pixels
    /// return nil rather than 1:1, because attaching a correction of one is a correction a consumer
    /// cannot tell from a real one.
    static func resolvePixelAspectRatio(
        bitstream: AVRational, container: AVRational, width: Int32, height: Int32
    ) -> AVRational? {
        PixelAspectPolicy.declaredPixelAspect(
            bitstream: bitstream, container: container, width: width, height: height)
    }

    // MARK: - Callback handling

    private final class FrameReceiver: @unchecked Sendable {
        weak var decoder: HardwareVideoDecoder?
        init(_ decoder: HardwareVideoDecoder) { self.decoder = decoder }
    }

    /// The buffer is retained across the queue hop and only touched by the serial delivery queue.
    private struct DecodedOutput: @unchecked Sendable {
        let imageBuffer: CVImageBuffer
        let pts: CMTime
    }

    /// VT owns/relinquishes the block on success, error, dropped frames and invalidation. There
    /// is no manually retained frameRefcon to leak or double-release. Do not promote weak self
    /// on VT's callback thread: releasing its last owner there could run deinit and self-drain.
    func outputHandler(for epoch: UInt64) -> VTDecompressionOutputHandler {
        let receiver = FrameReceiver(self)
        let queue = deliveryQueue
        return { status, flags, imageBuffer, pts, _ in
            guard status == noErr, !flags.contains(.frameDropped), let imageBuffer else { return }
            let output = DecodedOutput(imageBuffer: imageBuffer, pts: pts)
            queue.async {
                receiver.decoder?.handleDecodedFrame(imageBuffer: output.imageBuffer, pts: output.pts, epoch: epoch)
            }
        }
    }

    /// Epoch check, skip threshold and delivery are one operation relative to flush/close.
    /// No stale output can clear the next seek's threshold or call a replacement onFrame.
    private func handleDecodedFrame(
        imageBuffer: CVImageBuffer,
        pts: CMTime,
        epoch: UInt64
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard epoch == _feedEpoch else { return }
        if let threshold = skipUntilPTS {
            if CMTimeCompare(pts, threshold) < 0 {
                return
            }
            // Compare-and-clear: a concurrent seek can install a new threshold; blindly nil-ing would discard it.
            clearSkip(ifStillAt: threshold)
        }

        // Attach color metadata; without it HDR PQ content shows as desaturated SDR on AVSampleBufferDisplayLayer.
        if let primaries = colorPrimaries {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        if let transfer = colorTransfer {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        }
        if let matrix = colorMatrix {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }

        // #354: without this the renderer's format description carries no pixel aspect ratio and
        // anamorphic content is displayed at its coded dimensions.
        if let sar = pixelAspectRatio {
            let aspect: NSDictionary = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(sar.num),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(sar.den),
            ]
            CVBufferSetAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
        } else {
            // A recycled pool buffer can carry a stale attachment from an earlier stream.
            CVBufferRemoveAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey)
        }

        onFrame?(imageBuffer, pts, nil)
    }
}
