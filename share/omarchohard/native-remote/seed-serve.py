#!/usr/bin/env python3
"""Serve one file at one secret path over HTTP, for a limited time.

`omarchohard native seed serve` runs this to hand the stored Office seed to
the person's other devices on their tailnet, many at once.

    seed-serve.py ADDRESS PORT FILE SECONDS     (the path token in OH_SEED_TOKEN)

Only GET and HEAD of /<token>/<seed file name> answer; anything else is 404. The
token comes from the environment, not the command line, so other users on
this machine cannot read it from the process list, and it is never logged.
"""

import hmac
import http.server
import os
import sys
import threading

ADDRESS, PORT, PATH, SECONDS = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
TOKEN = os.environ.pop("OH_SEED_TOKEN", "")
if len(TOKEN) < 32:
    sys.exit("seed-serve: OH_SEED_TOKEN must hold at least 32 characters")
WANT = "/" + TOKEN + "/" + os.path.basename(PATH)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "omarchohard-seed"
    sys_version = ""

    def log_message(self, fmt, *args):
        # The request line carries the token; log only who and what status.
        pass

    def log_request(self, code="-", size="-"):
        sys.stderr.write("%s %s\n" % (self.client_address[0], code))

    def _start(self):
        if not hmac.compare_digest(self.path.encode(), WANT.encode()):
            self.send_error(404)
            return None
        f = open(PATH, "rb")
        size = os.fstat(f.fileno()).st_size
        self.send_response(200)
        self.send_header("Content-Type", "application/zstd")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        return f

    def do_HEAD(self):
        f = self._start()
        if f:
            f.close()

    def do_GET(self):
        f = self._start()
        if not f:
            return
        with f:
            try:
                self.wfile.flush()
                self.connection.sendfile(f)
            except (BrokenPipeError, ConnectionResetError):
                pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


server = Server((ADDRESS, PORT), Handler)
threading.Timer(SECONDS, server.shutdown).start()
sys.stderr.write("serving for %d s\n" % SECONDS)
server.serve_forever()
