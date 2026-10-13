# Partial H.264 MP4 composition-offset regression

## Reproduction

On the reported MP4, short playback at the head appeared normal. Seeking to about
700 seconds caused persistent judder. A short healthy-head check is not proof
that uninterrupted playback remains healthy past the malformed region.

Source characteristics: MP4, progressive SDR H.264 High level 4.0, 1920x1080,
nominal 30000/1001, time base 1/90000, AAC-LC 48 kHz. No HDR/Dolby Vision. Video
duration about 9438 seconds, 282860 samples. The edit/index lead is 6006 ticks.
No private source name, path, URL, packet payload or raw device log is published.

Direct sample-table inspection showed meaningful `ctts` offsets in the first
3272 samples, followed by one run of 279588 zero offsets. The table covers every
sample; it is not a truncated binary box. At 700 seconds all 240 inspected video
packets had PTS equal to DTS, but parsed POC reversed 68 times. Decoding a bounded
120-frame slice gave 34 original frame-PTS regressions. FFmpeg's monotonic
`best_effort_timestamp` is synthesized and does not prove those original times
correct. The device continued reporting about 30 FPS, enough buffered data and
no aggregate drops/stalls; those metrics do not establish picture-time ownership.

The first faulty sequence also changes interval: eleven 3600-tick steps followed
by 3003/3004 ticks within the same GOP. A short fixed-cadence prototype corrected
the later seek but failed the continuous boundary. It is not the submitted fix.
The submitted policy uses complete POC rank and the existing timestamp slots,
preserving original DTS instead of moving the already published index axis.

## Generated regression

Run on an Apple Silicon/Xcode development host, with FFmpeg CLI available:

```sh
bash Scripts/test-h264-partial-composition-controls.sh
```

The runtime compiler uses the exact `FFmpegBuild` revision in `Package.resolved`.
After normal package resolution it defaults to `.build/checkouts/FFmpegBuild`;
set `AETHER_FFMPEG_CHECKOUT` to an existing checkout at that exact revision when
needed. It does not resolve or update dependencies itself.

A third fixture is scene-cut shaped: a 30-picture zero-offset sequence followed
by one of 420. A uniform one-second GOP cannot reach the ceiling of a policy that
holds a sequence, so it also cannot show that ceiling gone. Measured at 30 fps
with one stereo AAC track, a sequence-wide hold was ended by its interleaved
packet budget at between 390 and 420 pictures, because 420 video packets carry
about 656 audio packets with them. Reading the slot instead of holding a plan
removes the ceiling rather than raising it: the deepest wait on that fixture is
6 packets, and the whole 1200-picture file comes back identical to its healthy
twin.

The fixture is generated solid colour plus tone, not an excerpt of any private
film. The generator keeps a healthy prefix and clears only later `ctts` offset
fields, without changing box lengths, DTS, compressed packets or audio. A second
fixture clears only the middle so the broken-to-healthy boundary is also tested.
The executable runs the actual parser and repair session against two decoders:
original versus repaired packet timestamps. It asserts zero repaired frame-PTS
regressions, exact original DTS, payload/metadata/non-video preservation and zero
tracked packet balance. Checks cover seek/back-seek, both continuous boundaries,
EOF, abandoned pending/ready queues, missing timestamps after confirmation and
the interleaved-packet budget. Numeric tests cover mixed cadence, quantization,
incomplete/field/duplicate POC, insufficient lead and integer overflow.

## Results and limits

The privately retained real-source runtime check passed at 0, 700, back to 0,
107, 112, 3600 and 9400 seconds. Original frame-PTS regressions were
0/49/0/20/50/48/46; all repaired results were zero. The 107-second check crosses
the first faulty sequence without a seek at the actual boundary. The generated
fixture also proves recovery back into healthy offsets without changing them.

The reporter verified the downstream implementation on an Apple TV 4K
(3rd generation), tvOS 26.6 beta (23L773), with the original source on the native
hardware H.264 route. The scoped upstream branch contains the same repair and
post-review malformed-timestamp guard; it does not include the host's diagnostic
framework, UI customizations, Matroska repair or software cache changes. The
generated fixture proves the packet/decoder regression; it is not claimed to
visually reproduce the original movie's native judder.

A refusal costs the repair and never the session: every held packet is handed
back exactly as it arrived and the rest of that sequence streams through, with
the next IDR a fresh candidate. The judder this policy removes is a far smaller
failure than a source read that stops.

This is a narrow compatibility policy, not a general VFR timestamp reconstructor.
It requires a corroborated healthy origin and complete closed progressive POC
sequences. Unsupported input is not re-timed by guessing its average frame rate.
Other operating systems, interlaced/open-GOP sources and arbitrary malformed
timelines have not been certified by the reported physical test.
