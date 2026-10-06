#!/usr/bin/env python3
import os
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
root = Path(os.environ['GALA_ARTIFACT_DIR']) / 'capture'
root.mkdir(parents=True, exist_ok=True)
class Capture(BaseHTTPRequestHandler):
    def do_GET(self):
        fixture = root / 'fixture.json'
        if self.path != '/fixture' or not fixture.exists():
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(fixture.read_bytes())
    def do_POST(self):
        kind = parse_qs(urlparse(self.path).query).get('kind', ['log'])[0]
        data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if kind == 'fixture':
            temporary = root / 'fixture.tmp'
            temporary.write_bytes(data); temporary.replace(root / 'fixture.json')
        elif kind == 'screenshot':
            (root / f'screenshot-{len(list(root.glob("*.png"))):04}.png').write_bytes(data)
        else:
            with (root / 'app.log').open('ab') as stream: stream.write(data)
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
HTTPServer(('127.0.0.1', 8765), Capture).serve_forever()
