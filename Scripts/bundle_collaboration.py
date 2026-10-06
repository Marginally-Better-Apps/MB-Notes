#!/usr/bin/env python3
"""Inline Vite's compiled React assets for static hosting and the native WKWebView."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
dist = root / 'CollaborationWeb/dist'
html = (dist / 'index.html').read_text()
def script(match):
    path = dist / match.group(1).lstrip('/')
    source = path.read_text().replace('</script', '<\\/script')
    return '<script type="module">' + source + '</script>'
def style(match):
    path = dist / match.group(1).lstrip('/')
    return '<style>' + path.read_text().replace('</style', '<\\/style') + '</style>'
html = re.sub(r'<script\b[^>]*\bsrc="([^"]+)"[^>]*></script>', script, html)
html = re.sub(r'<link\b[^>]*\bhref="([^"]+\.css)"[^>]*>', style, html)
assert 'src="/assets/' not in html and 'href="/assets/' not in html
(dist / 'index.html').write_text(html)
target = root / 'MBNotes/Resources/Collaboration'
target.mkdir(parents=True, exist_ok=True)
(target / 'index.html').write_text(html)
print(f'Standalone React client: {len(html.encode()):,} bytes')
