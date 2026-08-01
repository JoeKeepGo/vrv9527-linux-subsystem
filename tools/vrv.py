#!/usr/bin/env python3
"""VRV9527 helper: login and return SID.

Admin password is read from env VRV_ADMIN_PW (or argv[1]).
Router address from env VRV_HOST (default 192.168.1.254).
"""
import base64, hashlib, os, re, subprocess, urllib.parse, urllib.request, http.cookiejar, sys

BASE = "http://" + os.environ.get("VRV_HOST", "192.168.1.254")
PASSWORD = os.environ.get("VRV_ADMIN_PW") or (sys.argv[1] if len(sys.argv) > 1 else None)
if not PASSWORD and __name__ == "__main__":
    sys.exit("set VRV_ADMIN_PW or pass the admin password as argv[1]")

def arc_md5(s): return hashlib.sha512(hashlib.md5(s.encode()).hexdigest().encode()).hexdigest()

def aes(key, iv, data):
    return subprocess.run(["openssl", "enc", "-aes-256-cbc", "-K", key.hex(), "-iv", iv.hex(), "-nopad"],
                          input=data, capture_output=True, check=True).stdout

def pct(bs): return "".join("%%%02x" % b for b in bs)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None

def login():
    cj = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj), NoRedirect)
    html = op.open(BASE + "/login.htm", timeout=10).read().decode("utf-8", "replace")
    src = re.search(r'src="(data:image/gif;base64,[^"]+)"', html).group(1)
    raw = base64.b64decode(src[78:])
    key, iv, token = raw[:32], raw[32:48], raw[48:]
    usr = pct(aes(key, iv, arc_md5("admin").encode()))
    pws = pct(aes(key, iv, arc_md5(PASSWORD).encode()))
    body = urllib.parse.urlencode([("httoken", token.decode("latin-1")), ("pws", pws), ("usr", usr)]).encode()
    req = urllib.request.Request(BASE + "/login.cgi", data=body)
    req.add_header("Referer", BASE + "/login.htm")
    req.add_header("Origin", BASE)
    req.add_header("User-Agent", "Mozilla/5.0")
    try:
        op.open(req, timeout=10)
    except urllib.error.HTTPError as e:
        loc = e.headers.get("Location") or ""
        if "index.htm" not in loc:
            sys.exit(f"login failed: {e.code} {loc}")
        sc = e.headers.get("Set-Cookie")
    sid = None
    for c in cj:
        if c.name == "SID":
            sid = c.value
    if not sid:
        sys.exit("no SID cookie")
    return sid

def fresh_token(sid, page):
    req = urllib.request.Request(BASE + page)
    req.add_header("Cookie", f"SID={sid}")
    req.add_header("Referer", BASE + "/index.htm")
    html = urllib.request.urlopen(req, timeout=10).read().decode("utf-8", "replace")
    src = re.search(r'src="(data:image/gif;base64,[^"]+)"', html).group(1)
    raw = base64.b64decode(src[78:])
    return raw[48:].decode("latin-1")

if __name__ == "__main__":
    print(login())
