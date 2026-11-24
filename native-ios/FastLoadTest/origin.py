#!/usr/bin/env python3
# v1.0.80 (iOS): the loader test's file server (stdlib only) — like a debrid service, it sends each connection slowly
# (~3 MB/s), takes ranges (206 + Content-Range), and has /fail (500) and a no-range mode (every answer the whole
# file, 200). The Windows test's HttpListener, as a script the Mac test (main.swift) starts by itself.
#
#   python3 origin.py <file>      → prints "PORT <n>" once it listens on 127.0.0.1:<n>
#
# /_ctl?rate=<bytes/s>&ranges=0|1&resetMax=1&resetAsks=1 sets those and answers the counters as JSON
# ({"open", "maxOpen", "asks"}): requests being answered now, the most at once, and how many were asked for (the
# control address itself doesn't count).
# One source body. Many apertures. No compulsory simultaneity.
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DATA = open(sys.argv[1], "rb").read()
VIEW = memoryview(DATA)
state = {"rate": 3 * 1024 * 1024, "ranges": True, "open": 0, "maxOpen": 0, "asks": 0}
lock = threading.Lock()
CHUNK = 64 * 1024


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"   # (keep-alive, as a real server: the loader's connections are reused)

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def control(self, query):
        q = parse_qs(query)
        with lock:
            if "rate" in q:
                state["rate"] = max(1, int(q["rate"][0]))
            if "ranges" in q:
                state["ranges"] = q["ranges"][0] == "1"
            if "resetMax" in q:
                state["maxOpen"] = state["open"]
            if "resetAsks" in q:
                state["asks"] = 0
            body = json.dumps({k: state[k] for k in ("open", "maxOpen", "asks")}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve(self, body):
        u = urlparse(self.path)
        if u.path.startswith("/_ctl"):
            self.control(u.query)
            return
        with lock:
            state["open"] += 1
            state["asks"] += 1
            state["maxOpen"] = max(state["maxOpen"], state["open"])
            ranges = state["ranges"]
        try:
            if "/fail" in u.path:
                self.send_response(500)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            total = len(DATA)
            frm, to, partial = 0, total - 1, False
            rh = self.headers.get("Range")
            if ranges and rh and rh.startswith("bytes="):
                spec = rh[6:].split(",")[0].split("-")
                if spec[0] != "":
                    frm = int(spec[0])
                    if len(spec) > 1 and spec[1] != "":
                        to = min(int(spec[1]), total - 1)
                    partial = True
            if partial and (frm >= total or to < frm):
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % total)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(206 if partial else 200)
            self.send_header("Content-Type", "video/x-matroska")
            if ranges:
                self.send_header("Accept-Ranges", "bytes")
            if partial:
                self.send_header("Content-Range", "bytes %d-%d/%d" % (frm, to, total))
            self.send_header("Content-Length", str(to - frm + 1))
            self.end_headers()
            if not body:
                return
            # (paced per connection: the rate is read as it goes, so a test can speed it up)
            start = time.monotonic()
            sent = 0
            p = frm
            while p <= to:
                n = min(CHUNK, to - p + 1)
                self.wfile.write(VIEW[p:p + n])
                sent += n
                p += n
                wait = sent / state["rate"] - (time.monotonic() - start)
                if wait > 0.001:
                    time.sleep(wait)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, TimeoutError, OSError):
            self.close_connection = True   # (the loader let this connection go: a cancelled piece)
        finally:
            with lock:
                state["open"] -= 1


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128
    allow_reuse_address = True


if __name__ == "__main__":
    srv = Server(("127.0.0.1", 0), Handler)
    print("PORT %d" % srv.server_address[1], flush=True)
    srv.serve_forever()
