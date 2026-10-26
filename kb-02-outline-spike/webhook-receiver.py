import http.server
import json
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            parsed = json.loads(body)
            print(json.dumps(parsed, indent=2), flush=True)
        except Exception:
            print(body.decode(errors="replace"), flush=True)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, format, *args):
        pass

http.server.HTTPServer(("0.0.0.0", 9000), Handler).serve_forever()
