#!/usr/bin/env python3
"""A local stand-in for api.anthropic.com, for warm-replay.py tests.

Records the EXACT request bytes it received, streams a long SSE response, and
records whether the client hung up early. Nothing here talks to the network
beyond 127.0.0.1, and no credential is ever real.

Usage: fake_anthropic.py <outdir>
  writes <outdir>/port        the port it bound (poll for this)
         <outdir>/body.bin    raw request body of the last POST
         <outdir>/headers.json
         <outdir>/result      "client_disconnected" | "full_stream"
         <outdir>/requests    one line per request received
"""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = sys.argv[1]
CACHE_READ = 71410
# Big enough that a client hang-up surfaces as a write error rather than
# vanishing into the socket buffer.
CHUNKS, CHUNK_BYTES = 200, 4096


def rec(name, data, mode="w"):
    with open(os.path.join(OUT, name), mode) as fh:
        fh.write(data)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        rec("body.bin", "")
        with open(os.path.join(OUT, "body.bin"), "wb") as fh:
            fh.write(body)
        rec("headers.json", json.dumps(dict(self.headers)))
        rec("requests", self.path + "\n", "a")

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        start = {
            "type": "message_start",
            "message": {"usage": {
                "input_tokens": 4,
                "cache_read_input_tokens": CACHE_READ,
                "cache_creation_input_tokens": 0,
            }},
        }
        try:
            self.wfile.write(("data: " + json.dumps(start) + "\n\n").encode())
            self.wfile.flush()
            filler = "x" * CHUNK_BYTES
            for _ in range(CHUNKS):
                ev = {"type": "content_block_delta", "delta": {"text": filler}}
                self.wfile.write(("data: " + json.dumps(ev) + "\n\n").encode())
                self.wfile.flush()
                time.sleep(0.005)
            done = {"type": "message_delta", "usage": {"output_tokens": 1}}
            self.wfile.write(("data: " + json.dumps(done) + "\n\n").encode())
            self.wfile.flush()
            rec("result", "full_stream")
        except (BrokenPipeError, ConnectionResetError):
            rec("result", "client_disconnected")


def main():
    os.makedirs(OUT, exist_ok=True)
    srv = HTTPServer(("127.0.0.1", 0), Handler)
    with open(os.path.join(OUT, "port.tmp"), "w") as fh:
        fh.write(str(srv.server_port))
    os.rename(os.path.join(OUT, "port.tmp"), os.path.join(OUT, "port"))
    srv.serve_forever()


if __name__ == "__main__":
    main()
