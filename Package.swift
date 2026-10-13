// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AetherEngine",
            targets: ["AetherEngine"]
        ),
        .library(
            name: "AetherEngineSMB",
            targets: ["AetherEngineSMB"]
        ),
        // aetherctl is intentionally not exposed as a product. The target
        // uses Foundation.Process, which is unavailable on tvOS/iOS, so
        // exposing it would force SPM consumers to compile it on those
        // platforms. The target is preserved below so `swift build` on
        // macOS still produces the CLI for upstream development.
    ],
    dependencies: [
        // Minimal FFmpeg build (avcodec, avformat, avutil, swresample only).
        // No network stack, we use custom AVIO + URLSession for HTTP streams.
        // Resolved over Git rather than a local path so consumers (and
        // Xcode Cloud) can build without a sibling FFmpegBuild checkout.
        // Pinned to the minor rather than `from:`: this package ships the
        // prebuilt decode stack, so a floating minor silently changes which
        // FFmpeg a released engine tag runs (2.3.0 -> 2.4.0 did exactly that
        // under 5.28.0), and a minor that raises a platform floor retroactively
        // breaks every tag that floats onto it (LibDovi 1.1.0, below). Patch
        // rebuilds still reach existing tags, which is where a pure rebuild
        // belongs; anything that adds slices or enables a component is a minor
        // and reaches consumers through an engine release.
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", .upToNextMinor(from: "3.4.0")),  // 3.4.0: FFmpeg learns the `dav1` sample entry in both directions, the AV1 variant of `av01` that signals Dolby Vision, so a Profile 10.0 source can be read at all and can be remuxed with the tag its packaging requires; stock FFmpeg has it in neither of its two mp4 tag tables, so the read probes as "unknown codec" and the write fails EINVAL (#547); same n8.1.2 binaries as 3.3.0 otherwise, compiled against the Xcode 27 SDKs with unchanged deployment targets; 3.3.0: every slice a shipped app can embed carries its dSYM inside the xcframework, so Xcode copies it into `.xcarchive/dSYMs` and a crash inside FFmpeg symbolicates instead of staying a list of addresses (FFmpegBuild#4); same n8.1.2 binaries as 3.2.1 apart from their UUID, the libraries just compile with `-gline-tables-only` now and the debug map is harvested before the shipped binary is stripped; 3.2.1: vc1_parser seeds its parse context from extradata, so a seek landing on an entry point alone keeps its picture size instead of falling back to 0x0 or to a size read out of the following payload (#490, FFmpeg PR 24458); 3.2.0: the legacy Flash tail, video and audio together (flv1 / vp6 / vp6f / vp6a, nellymoser, adpcm_swf, speex, and FLV's pcm_s16be / pcm_u8 / pcm_alaw / pcm_mulaw), so a pre-2008 .flv plays with sound where before only H.264-in-FLV did; flashsv stays out, it needs zlib and would have been dropped silently; 3.1.0: native .wmv / .asf, the asf demuxer plus every WMA decoder (Standard, Pro, Lossless, Voice), which is the container half of the legacy Microsoft support 2.4.3 started (FFmpegBuild#3); 3.0.0: every target, product, framework bundle and install name carries an `Aether` prefix, so this build can sit in an app that already has an FFmpeg (FFmpegKit, MobileVLCKit, mpv); same n8.1.2 binaries as 2.5.0, only names changed; 2.5.0: libzvbi 0.2.45 for GHSA-86rm-g7qf-j2fh (OOB read/write + integer underflow, reachable through the libzvbi_teletext decoder), dav1d 1.5.4, zimg 3.0.6, and the concat demuxer removed (a script demuxer selectable by probing alone, which made any stream a potential file-open primitive); 2.4.3: the legacy Microsoft video decoders (msmpeg4v1/v2/v3, wmv1/wmv2/wmv3; FFmpegBuild#3); 2.4.2: pgssubdec missing-palette recovery, replaces the 2.1.1 Epoch-Continue retain (#142); 2.4.1: qtrle decoder; 2.4.0: visionOS (xros) device + simulator slices; 2.3.0: webvtt demuxer (standalone .vtt sidecars, plus the cue settings as packet side data); 2.2.0: matroska TTS warn-only per RFC 9559 (#145 rework); 2.1.3: sup demuxer (raw PGS sidecars); 2.1.2: matroska TrackTimestampScale clamp (#145, dropped in 2.2.0); 2.1.1: pgssubdec Epoch-Continue retain (#142); 2.1.0: yadif_videotoolbox + hwupload (Metal GPU deinterlace); 2.0.0: dynamic frameworks (LGPL), zvbi GPL excision
        // Pure-Swift SMB2 client (MIT) that speaks the protocol over
        // NWConnection. Replaces AMSMB2/libsmb2, which EPERMs on tvOS/iOS.
        // Pinned to the 0.3.x minor: SMBClient is pre-1.0 with an actively
        // moving API, so allow patch updates but not a minor bump.
        .package(url: "https://github.com/kishikawakatsumi/SMBClient", .upToNextMinor(from: "0.3.1")),
        // libdovi (Dolby Vision RPU parser/converter). Resolved over Git like
        // FFmpegBuild so consumers (and Xcode Cloud) build without a sibling
        // LibDovi checkout; the prebuilt xcframework needs no Rust at build time.
        // Pinned to the minor for the same reason as FFmpegBuild above, with a
        // worked example: 1.1.0 shipped a tvOS floor raise as a minor, SwiftPM
        // floated every `from: "1.0.x"` consumer onto it and then failed on the
        // floor instead of backing off, so all of 5.x stopped resolving.
        .package(url: "https://github.com/superuser404notfound/LibDovi", .upToNextMinor(from: "2.1.0")),  // 2.1.0: dolby_vision 3.4.0, header additive only (two new CMv4.0 metadata entry points, nothing removed); 2.0.0: visionOS (xros) device + simulator slices, declared tvOS floor corrected to 17.0 (was published as 1.1.0, withdrawn: a floor raise is breaking and broke every 5.x pin that floated onto it); 1.0.2: iOS slices + x86_64 (Intel Macs)
    ],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
                .product(name: "Dovi", package: "LibDovi"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .target(
            name: "AetherEngineSMB",
            dependencies: [
                "AetherEngine",
                .product(name: "SMBClient", package: "SMBClient"),
            ],
            path: "Sources/AetherEngineSMB"
        ),
        .executableTarget(
            name: "aetherctl",
            dependencies: ["AetherEngine", "AetherEngineSMB"],
            path: "Sources/aetherctl"
        ),
        // The samples in Examples/ are drop-in files rather than apps, so nothing used to
        // compile them and they could rot the way prose rots, except a reader trusts them
        // more. Compiling them as a target (never a product, so no consumer builds it)
        // makes `swift build` and CI the guard. DemoPlayerMac is its own package and
        // excluded here; it builds with `swift build --package-path Examples/DemoPlayerMac`.
        .target(
            name: "ExampleSources",
            dependencies: ["AetherEngine"],
            path: "Examples",
            exclude: ["README.md", "DemoPlayerMac"]
        ),
        .testTarget(
            name: "AetherEngineTests",
            dependencies: ["AetherEngine"],
            path: "Tests/AetherEngineTests"
        ),
        .testTarget(
            name: "AetherEngineSMBTests",
            dependencies: ["AetherEngineSMB"],
            path: "Tests/AetherEngineSMBTests"
        ),
    ]
)
