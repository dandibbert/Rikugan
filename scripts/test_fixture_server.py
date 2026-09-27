"""Verify the exact HTTP fixture bytes and Range contract without an iOS device."""
from functools import partial
from http.server import ThreadingHTTPServer
from threading import Thread
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from fixture_server import Handler, ROOT, SIZE


def main():
    # No host MIME database dependency for these known fixture types.
    Handler.extensions_map = {**Handler.extensions_map, ".html": "text/html"}
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(ROOT)))
    Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}/__download.bin"
    try:
        try:
            urlopen(url, timeout=10)
        except HTTPError as error:
            assert error.code == 403
        else:
            raise AssertionError("Missing login cookie was accepted")

        initial = urlopen(Request(url, headers={"Cookie": "download-auth=yes"}), timeout=10)
        try:
            assert initial.status == 200
            prefix = initial.read(32768)
            assert prefix == b"R" * 32768
        finally:
            initial.close()  # The pause/cancel boundary.

        request = Request(url, headers={"Cookie": "download-auth=yes", "Range": "bytes=32768-"})
        with urlopen(request, timeout=10) as response:
            assert response.status == 206
            assert response.headers["Content-Range"] == f"bytes 32768-{SIZE - 1}/{SIZE}"
            suffix = response.read()
            assert int(response.headers["Content-Length"]) == len(suffix)
            assert prefix + suffix == b"R" * SIZE

        try:
            urlopen(Request(url, headers={"Cookie": "download-auth=yes", "Range": f"bytes={SIZE}-"}), timeout=10)
        except HTTPError as error:
            assert error.code == 416
        else:
            raise AssertionError("Invalid Range was accepted")
        print("PASS: authenticated download, cancellation boundary, exact 4 MiB Range reconstruction and invalid range rejection")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
