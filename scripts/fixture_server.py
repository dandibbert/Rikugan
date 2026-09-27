"""Local, deterministic browser fixtures, including authenticated Range downloads."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from functools import partial
import re
import time
import json
import base64

ROOT = Path(__file__).resolve().parents[1] / "Tests" / "Fixtures"
SIZE = 4 * 1024 * 1024


class Handler(SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path.split("?")[0] != "/__echo":
            return self.send_error(404)
        length = int(self.headers.get("Content-Length", "0"))
        if length > 2_000_000:
            return self.send_error(413)
        self.echo(self.rfile.read(length))

    def echo(self, body=b""):
        data = json.dumps({"method": self.command, "body": base64.b64encode(body).decode(),
                           "contentType": self.headers.get("Content-Type", ""),
                           "cookie": self.headers.get("Cookie", "")}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/__private-image.png":
            if "download-auth=yes" not in self.headers.get("Cookie", ""):
                return self.send_error(403, "Missing browser login cookie")
            data = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
            self.send_response(200); self.send_header("Content-Type", "image/png"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        if path == "/__echo":
            return self.echo()
        if path == "/__redirect":
            self.send_response(302)
            self.send_header("Location", "http://localhost:8765/__echo")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/__slow":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(64 * 1024))
            self.end_headers()
            try:
                for _ in range(64):
                    self.wfile.write(b"x" * 1024)
                    self.wfile.flush()
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError):
                self.log_message("SLOW client cancelled")
            return
        if self.path.split("?")[0] != "/__download.bin":
            return super().do_GET()
        if "download-auth=yes" not in self.headers.get("Cookie", ""):
            return self.send_error(403, "Missing browser login cookie")
        value = self.headers.get("Range")
        start, end = 0, SIZE - 1
        if value:
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", value)
            if not match:
                return self.send_error(416)
            start = int(match[1])
            end = min(int(match[2]) if match[2] else end, SIZE - 1)
            if not 0 <= start <= end:
                return self.send_error(416)
        self.send_response(206 if value else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="fixture.bin"')
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"rikugan-download-v1"')
        self.send_header("Last-Modified", "Sun, 27 Sep 2026 00:00:00 GMT")
        if value:
            self.send_header("Content-Range", f"bytes {start}-{end}/{SIZE}")
        self.end_headers()
        self.log_message("DOWNLOAD start range=%s start=%d end=%d", value, start, end)
        try:
            while start <= end:
                length = min(32768, end - start + 1)
                self.wfile.write(b"R" * length)
                self.wfile.flush()
                start += length
                # Only the initial transfer needs a pause/cancel opportunity.
                # Pacing every resumed chunk turns this functional test into a
                # shared-runner scheduling benchmark (4 MiB took 19 seconds just
                # to leave the fixture server). Preserve the same bytes, Range
                # response and client timeout; send resumed bytes without sleeps.
                if not value:
                    time.sleep(0.03)
            self.log_message("DOWNLOAD sent through byte=%d", start - 1)
        except (BrokenPipeError, ConnectionResetError):
            self.log_message("DOWNLOAD client closed after byte=%d", start - 1)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8765), partial(Handler, directory=str(ROOT))).serve_forever()
