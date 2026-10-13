import Foundation

/// Custom byte source for `AetherEngine.load(source:)`. Use for memory buffers, encrypted containers, or anything not a plain URL. `read`/`seek` run on the engine's demux thread (not main); `close()` is called exactly once at teardown, never between probe and playback. The engine wraps every call into a reader in an autorelease pool, so a reader is free to use Foundation APIs that hand back autoreleased objects (`FileHandle`, `NSData`) without stranding one per read on a pump thread that runs for the length of the session.
public protocol IOReader: AnyObject, Sendable {
    /// Read up to `size` bytes into `buffer`. Return bytes read, `0` on EOF, or negative on error. The `buffer` optional reflects the C import convention; the engine never passes nil.
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32

    /// Reposition the source. `whence`: `SEEK_SET`/`SEEK_CUR`/`SEEK_END` or `AVSEEK_SIZE` (65536, return total size without moving). Return new absolute position or negative on error/unsupported direction. Forward-only sources (AVIO live streams) are supported on the software path only.
    func seek(offset: Int64, whence: Int32) -> Int64

    func close()

    /// Unblock a pending `read` so teardown does not hang. Network readers cancel the in-flight request; memory/file readers can leave this as the default no-op. For readers the engine may reload: unblock only, do not invalidate.
    func cancel()

    /// Return an independent reader with its own cursor over the same source for concurrent access (side demuxer, scrub previews). Return nil for one-shot streams; the engine skips that feature. The returned reader is owned and closed by the engine.
    func makeIndependentReader() -> IOReader?

    /// Whether the engine should inspect this custom byte source for an ISO/UDF disc image before
    /// opening it as an ordinary media container. Keep the default for raw disc images. Remote
    /// readers that already know they represent a regular media file can return `false` to avoid
    /// the sparse signature reads performed by disc recognition. Independent readers should
    /// preserve the same value.
    var discImageProbeEnabled: Bool { get }
}

/// Internal seam for finite segmented sources whose natural seek axis is time,
/// not a synthetic concatenated byte offset.
protocol TimeSeekableIOReader: IOReader {
    /// Total media duration in seconds, from the source's own manifest.
    var mediaDuration: Double { get }

    /// Reposition to `seconds` of ELAPSED MEDIA TIME (0 = first byte the reader would deliver from a
    /// fresh open), never an absolute container PTS: the caller strips the source's PTS origin first
    /// (`Demuxer.repositionTimeSeekable`). Landing at or before the requested time is the contract;
    /// the demuxer's packet gate drops what precedes the exact target.
    func seek(to seconds: Double) -> Bool

    /// Elapsed media time in front of each of the source's own segments, ascending, starting at 0.
    /// These are the source's declared random-access points: the segment plan is built on them so
    /// every advertised boundary is one the producer's keyframe gate can actually open (AE#268).
    /// Empty when the reader has no segment structure to report.
    var segmentStartTimesSeconds: [Double] { get }
}

extension TimeSeekableIOReader {
    var segmentStartTimesSeconds: [Double] { [] }
}

public extension IOReader {
    func cancel() {}
    func makeIndependentReader() -> IOReader? { nil }
    var discImageProbeEnabled: Bool { true }
}

/// The source AetherEngine loads media from.
public enum MediaSource: Sendable {
    case url(URL)
    /// `formatHint`: optional container short name ("mp4", "matroska", "mpegts") to disambiguate probing when no filename is present; nil probes from content.
    case custom(IOReader, formatHint: String? = nil)
    /// A finite sequence of independently demuxable, muxed media files. Aether opens each
    /// segment with its own AVFormatContext and joins decoded packets on one elapsed timeline;
    /// bytes are never concatenated into a synthetic container.
    case sequence(MediaSequence)
    /// One programme delivered as two separate renditions — video-only and audio-only.
    /// Aether opens each with its own AVFormatContext and interleaves their packets on one
    /// timeline; the renditions are never concatenated, remuxed, or handed to a second player.
    case separated(SeparatedMedia)
}

/// Packet-level input for a programme whose video and audio arrive as separate resources,
/// as DASH delivers them. Both renditions share the headers passed through `LoadOptions`.
///
/// The two renditions' real start times are both preserved: Aether rebases them onto one
/// shared session origin, so an intended offset between them survives rather than being
/// flattened by zeroing each side against its own first packet.
public struct SeparatedMedia: Sendable {
    public let videoURL: URL
    public let audioURL: URL
    /// Alternate origins for the same rendition, in the caller's preferred order. A rendition that
    /// stops being readable is replaced from its own list — the other rendition is never swapped
    /// to compensate — and the replacement must describe the same stream before it is accepted.
    /// Empty means that rendition has no alternate origin and its failure ends the session.
    public let videoFallbackURLs: [URL]
    public let audioFallbackURLs: [URL]
    /// Programme duration when the caller knows it. Omit to take it from the containers, which
    /// is the longer of the two renditions.
    public let duration: Double?

    public init(videoURL: URL, audioURL: URL,
                videoFallbackURLs: [URL] = [], audioFallbackURLs: [URL] = [],
                duration: Double? = nil) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.videoFallbackURLs = videoFallbackURLs
        self.audioFallbackURLs = audioFallbackURLs
        self.duration = duration
    }
}

/// Packet-level timeline input for finite muxed sequences. Segment URLs share the headers passed
/// through `LoadOptions`; each segment must contain the same video/audio stream layout as the first.
/// The declared duration is preferred for timeline placement and may be omitted when the container
/// duration is trustworthy.
public struct MediaSequence: Sendable {
    public struct Segment: Sendable {
        public let url: URL
        public let duration: Double?

        public init(url: URL, duration: Double? = nil) {
            self.url = url
            self.duration = duration
        }
    }

    public let segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }
}
