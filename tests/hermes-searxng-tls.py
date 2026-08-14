#!/usr/bin/env python3

import http.server
import ssl
import sys
import threading

import httpx


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, _format, *args):
        pass


class Server(http.server.HTTPServer):
    def handle_error(self, _request, _client_address):
        pass


def main():
    cert, key, expected = sys.argv[1:]
    server = Server(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    url = f"https://127.0.0.1:{server.server_port}/"

    try:
        try:
            response = httpx.get(url, timeout=5)
        except httpx.ConnectError:
            if expected == "fail":
                return
            raise
        if expected == "fail":
            raise AssertionError("test CA was trusted without SSL_CERT_FILE")
        response.raise_for_status()
        assert response.text == "ok"
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


if __name__ == "__main__":
    main()
