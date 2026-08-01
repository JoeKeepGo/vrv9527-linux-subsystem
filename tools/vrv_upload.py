#!/usr/bin/env python3
"""One-shot: login, fetch token, upload config restore, print result."""
import base64, re, sys, urllib.request, urllib.error, http.cookiejar
sys.path.insert(0, '/tmp')
from vrv import login, BASE

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None

def main(path):
    sid = login()
    cj = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj), NoRedirect)
    # token from system_backup.htm (strip 78-char prefix like vrv.login does)
    req = urllib.request.Request(BASE + '/system_backup.htm',
        headers={'Cookie': f'SID={sid}', 'Referer': BASE + '/index.htm'})
    html = op.open(req, timeout=10).read().decode('utf-8', 'replace')
    src = re.search(r'src="(data:image/gif;base64,[^"]+)"', html).group(1)
    raw = base64.b64decode(src[78:])
    token = raw[48:].decode('latin-1')
    print('sid ok, token len', len(token))

    # multipart body
    boundary = '----pyboundary1234'
    data = open(path, 'rb').read()
    parts = []
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="httoken"\r\n\r\n{token}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="restore"; filename="SmartModem_backup.cfg"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode())
    parts.append(data)
    parts.append(f'\r\n--{boundary}--\r\n'.encode())
    body = b''.join(parts)
    req = urllib.request.Request(BASE + '/upload.cgi', data=body,
        headers={'Cookie': f'SID={sid}', 'Referer': BASE + '/system_backup.htm',
                 'Content-Type': f'multipart/form-data; boundary={boundary}'})
    try:
        r = op.open(req, timeout=170)
        code, hdrs, resp = r.code, r.headers, r.read()
    except urllib.error.HTTPError as e:
        code, hdrs, resp = e.code, e.headers, e.read()
    print('HTTP', code, 'Location:', hdrs.get('Location'))
    m = re.search(rb'G_err[^;]{0,20}', resp)
    print('G_err:', m.group(0).decode() if m else '(none)', 'body len', len(resp))

if __name__ == '__main__':
    main(sys.argv[1])
