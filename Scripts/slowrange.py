#!/usr/bin/env python3
"""A one-file range origin with a DELAY and a rate SHARED across all in-flight responses.

    python3 Scripts/slowrange.py <file> <port> <kbps> <delay-seconds>

Loopback answers instantly and at memory speed, which is the one thing no real origin does, so a
request COUNT taken from it is trustworthy and a TIMING claim never is. Two knobs turn it into a
link, and both matter:

  * a delay paid by EVERY response header, because requests cross the same origin and pay the same
    round trip. Without it anything speculative always lands before the demuxer needs it.
  * a rate advanced under one lock on a virtual clock, so two connections SHARE it. A per-connection
    sleep hands the second reader free bandwidth, which is the opposite of a slow link.

`Scripts/throttle-origin.py` is the other shape: a proxy that puts a real server behind a rate, with
no delay of its own. Use this one when the fixture is a local file and the question needs latency.

This is the origin the AE#418 placement measurements were run on. The long chain, ten placements out
of twenty-four seeks, is reproduced with:

    Scripts/timecode-fixture.sh /tmp/ae418
    python3 Scripts/mkv-cue-fixture.py /tmp/ae418/tc-drought.mkv /tmp/ae418/tc-cues-lie.mkv \
        "$(python3 -c 'print(",".join(str(i) for i in range(1,120)))')"
    python3 Scripts/slowrange.py /tmp/ae418/tc-cues-lie.mkv 8871 3200 0.1 &
    aetherctl play --seconds 62 --start-position 53 --picture-probe --seek-every 2 --seek-count 24 \
      --seek-pattern 65,60,70,58,75,50,85,45,90,40,95,35,100,30,105,25,110,22,64,59,69,57,74,49 \
      http://127.0.0.1:8871/tc-cues-lie.mkv

The link is not a detail of that run, it is a variable of it. Measured over 11 sessions on one build:
3200 kbps / 100 ms gives ten placements and a final axis of -34.376 s, 1200 kbps / 200 ms gives seven
and -9.043 s, 600 kbps / 300 ms gives eight and -14.793 s, each reproducing exactly within its own
condition. The two slow shapes also produce the reading taken off a timeline AVPlayer rebuilt, which
the fast one never does. So a placement census belongs next to any number measured from a session,
and two sittings of the same arms over different links are not two samples of one quantity.
"""
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PATH = sys.argv[1]
PORT = int(sys.argv[2])
KBPS = float(sys.argv[3])
DELAY = float(sys.argv[4])
SIZE = os.path.getsize(PATH)
CHUNK = 32 * 1024

_lock = threading.Lock()
_free_at = time.monotonic()


def pace(nbytes):
    """Advance the shared virtual clock by what these bytes cost, then wait for it."""
    global _free_at
    with _lock:
        now = time.monotonic()
        if _free_at < now:
            _free_at = now
        _free_at += nbytes * 8.0 / (KBPS * 1000.0)
        wait = _free_at - now
    if wait > 0:
        time.sleep(wait)


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.0 so every request closes: keep-alive muddies a request log.
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        pass

    def do_HEAD(self):
        time.sleep(DELAY)
        self.send_response(200)
        self.send_header("Content-Length", str(SIZE))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

    def do_GET(self):
        rng = self.headers.get("Range")
        start, end, partial = 0, SIZE - 1, False
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng.strip())
            if m:
                a, b = m.group(1), m.group(2)
                # The suffix form (bytes=-n) is the one a tail read uses, and the one a
                # hand-written origin usually gets wrong.
                if a == "" and b:
                    start, end = max(0, SIZE - int(b)), SIZE - 1
                else:
                    start = int(a)
                    end = int(b) if b else SIZE - 1
                end = min(end, SIZE - 1)
                partial = True
        if start > end or start >= SIZE:
            time.sleep(DELAY)
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % SIZE)
            self.end_headers()
            return
        length = end - start + 1
        time.sleep(DELAY)
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "video/x-matroska")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, SIZE))
        self.end_headers()
        sent = 0
        with open(PATH, "rb") as f:
            f.seek(start)
            while sent < length:
                buf = f.read(min(CHUNK, length - sent))
                if not buf:
                    break
                pace(len(buf))
                try:
                    self.wfile.write(buf)
                except (BrokenPipeError, ConnectionResetError):
                    # Said out loud: a body that ends quietly is indistinguishable from a
                    # client-side stall and gets read as one.
                    sys.stderr.write("CLOSED after %d of %d bytes\n" % (sent, length))
                    return
                sent += len(buf)
        sys.stderr.write("SERVED %d-%d (%d bytes)\n" % (start, end, sent))


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write("origin %s on :%d, %.0f kbps shared, %.0f ms delay, %d bytes\n"
                     % (os.path.basename(PATH), PORT, KBPS, DELAY * 1000, SIZE))
    srv.serve_forever()
