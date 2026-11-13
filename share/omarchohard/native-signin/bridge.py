#!/usr/bin/env python3
"""omarchohard's sign-in bridge: Microsoft's sign-in in a real browser.

Office runs on a hidden screen. Its sign-in window (WebView2 under Wine) asks
Microsoft for an authorization code with PKCE. This bridge takes that request
before it loads, opens it in a native Chromium window (or, with --remote, a
headless one shown on a phone or another computer), catches Microsoft's
answer and hands it back to Office, which redeems the code itself. Passkeys,
security keys and the browser's speed come with the real browser; nothing
here reads or keeps a token.

Standard library only. Talks the Chrome DevTools Protocol to both browsers:
over a loopback WebSocket to Office's WebView2 and over a pipe (no port) to
Chromium.
"""

import argparse
import base64
import ctypes
import hmac
import http.server
import json
import os
import queue
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
# The request Office's sign-in window makes for the code; work and personal
# accounts both start here.
AUTHORIZE = "https://login.microsoftonline.com/*/oauth2/v2.0/authorize*"
# Microsoft's answer: a redirect to the urn (work or school), or the
# desktop page on login.live.com (personal).
OOB = "urn:ietf:wg:oauth:2.0:oob"
DESKTOP = "https://login.live.com/oauth20_desktop.srf"


def log(msg):
    print("signin: " + msg, file=sys.stderr, flush=True)


class CDPError(Exception):
    pass


class CDP:
    """One DevTools connection. Events go to handlers on their own thread, so
    a handler may call back into the browser."""

    def __init__(self, send_raw):
        self._send_raw = send_raw
        self._id = 0
        self._lock = threading.Lock()
        self._waiters = {}
        self._handlers = {}
        self._events = queue.Queue()
        self.closed = threading.Event()
        threading.Thread(target=self._pump, daemon=True).start()

    def on(self, method, fn):
        self._handlers.setdefault(method, []).append(fn)

    def call(self, method, params=None, session=None, timeout=20):
        with self._lock:
            self._id += 1
            i = self._id
            done = threading.Event()
            self._waiters[i] = [done, None]
        msg = {"id": i, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        self._send_raw(json.dumps(msg))
        if not done.wait(timeout):
            self._waiters.pop(i, None)
            raise CDPError(method + ": no answer")
        reply = self._waiters.pop(i)[1]
        if "error" in reply:
            raise CDPError("%s: %s" % (method, reply["error"].get("message")))
        return reply.get("result", {})

    def feed(self, text):
        m = json.loads(text)
        if "id" in m:
            w = self._waiters.get(m["id"])
            if w:
                w[1] = m
                w[0].set()
        else:
            self._events.put(m)

    def _pump(self):
        while True:
            m = self._events.get()
            for fn in self._handlers.get(m.get("method"), []):
                try:
                    fn(m.get("params", {}), m.get("sessionId"))
                except Exception as e:  # one bad event never stops the rest
                    log("%s: %s" % (m.get("method"), e))


def ws_cdp(url):
    """A DevTools WebSocket, client side of RFC 6455: text frames only."""
    u = urllib.parse.urlsplit(url)
    s = socket.create_connection((u.hostname, u.port), timeout=10)
    nonce = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n" % (u.path, u.hostname, u.port, nonce)).encode())
    f = s.makefile("rb")
    status = f.readline()
    if b" 101 " not in status:
        raise CDPError("WebView2 refused the connection: %r" % status)
    while f.readline() not in (b"\r\n", b""):
        pass
    s.settimeout(None)
    wlock = threading.Lock()

    def frame(op, data):
        n = len(data)
        head = bytes([0x80 | op])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + n.to_bytes(2, "big")
        else:
            head += bytes([0x80 | 127]) + n.to_bytes(8, "big")
        mask = os.urandom(4)
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        with wlock:
            s.sendall(head + mask + body)

    cdp = CDP(lambda text: frame(1, text.encode()))

    def reader():
        buf = b""
        try:
            while True:
                b0, b1 = f.read(2)
                n = b1 & 0x7F
                if n == 126:
                    n = int.from_bytes(f.read(2), "big")
                elif n == 127:
                    n = int.from_bytes(f.read(8), "big")
                if b1 & 0x80:
                    mask = f.read(4)
                    data = bytes(b ^ mask[i % 4] for i, b in enumerate(f.read(n)))
                else:
                    data = f.read(n)
                op = b0 & 0x0F
                if op == 8:
                    break
                if op == 9:
                    frame(10, data)
                    continue
                if op in (0, 1):
                    buf += data
                    if b0 & 0x80:
                        cdp.feed(buf.decode())
                        buf = b""
        except (OSError, ValueError):
            pass
        cdp.closed.set()

    threading.Thread(target=reader, daemon=True).start()
    cdp.sock = s
    return cdp


def pipe_cdp(rfd, wfd):
    """Chromium's --remote-debugging-pipe: JSON messages ended by NUL."""
    wlock = threading.Lock()

    def send(text):
        data = text.encode() + b"\0"
        with wlock:
            while data:
                data = data[os.write(wfd, data):]

    cdp = CDP(send)

    def reader():
        buf = b""
        while True:
            try:
                chunk = os.read(rfd, 1 << 16)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while b"\0" in buf:
                msg, buf = buf.split(b"\0", 1)
                cdp.feed(msg.decode())
        cdp.closed.set()

    threading.Thread(target=reader, daemon=True).start()
    return cdp


class X11:
    """The hidden screen. Office's first window ("Sign in to set up Office")
    is native, not a web page, so its button gets one click through XTEST.
    Xvfb has no window manager, so a key press would reach Word instead."""

    def __init__(self, display):
        W = ctypes.c_ulong
        P = ctypes.POINTER
        x = ctypes.CDLL("libX11.so.6")
        t = ctypes.CDLL("libXtst.so.6")
        x.XOpenDisplay.restype = ctypes.c_void_p
        x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x.XDefaultRootWindow.restype = W
        x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        x.XQueryTree.argtypes = [ctypes.c_void_p, W, P(W), P(W), P(P(W)), P(ctypes.c_uint)]
        x.XFetchName.argtypes = [ctypes.c_void_p, W, P(ctypes.c_char_p)]
        x.XFree.argtypes = [ctypes.c_void_p]
        x.XGetGeometry.argtypes = [ctypes.c_void_p, W, P(W)] + [P(ctypes.c_int)] * 2 + [P(ctypes.c_uint)] * 4
        x.XTranslateCoordinates.argtypes = [ctypes.c_void_p, W, W, ctypes.c_int, ctypes.c_int,
                                            P(ctypes.c_int), P(ctypes.c_int), P(W)]
        x.XFlush.argtypes = [ctypes.c_void_p]
        t.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
        t.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self.x, self.t, self.W = x, t, W
        self.dpy = x.XOpenDisplay(display.encode())
        if not self.dpy:
            raise OSError("cannot open display " + display)
        self.root = x.XDefaultRootWindow(self.dpy)

    def find(self, title, win=None):
        W = self.W
        win = self.root if win is None else win
        name = ctypes.c_char_p()
        if self.x.XFetchName(self.dpy, win, ctypes.byref(name)) and name.value == title.encode():
            return win
        r, p, kids, n = W(), W(), ctypes.POINTER(W)(), ctypes.c_uint()
        if not self.x.XQueryTree(self.dpy, win, ctypes.byref(r), ctypes.byref(p), ctypes.byref(kids), ctypes.byref(n)):
            return None
        found = None
        for i in range(n.value):
            found = self.find(title, kids[i])
            if found:
                break
        if kids:
            self.x.XFree(kids)
        return found

    def rect(self, win):
        r, child = self.W(), self.W()
        x, y, ax, ay = ctypes.c_int(), ctypes.c_int(), ctypes.c_int(), ctypes.c_int()
        w, h, bw, d = ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
        self.x.XGetGeometry(self.dpy, win, ctypes.byref(r), ctypes.byref(x), ctypes.byref(y),
                            ctypes.byref(w), ctypes.byref(h), ctypes.byref(bw), ctypes.byref(d))
        self.x.XTranslateCoordinates(self.dpy, win, self.root, 0, 0, ctypes.byref(ax), ctypes.byref(ay), ctypes.byref(child))
        return ax.value, ay.value, w.value, h.value

    def click(self, x, y):
        self.t.XTestFakeMotionEvent(self.dpy, -1, x, y, 0)
        self.t.XTestFakeButtonEvent(self.dpy, 1, 1, 0)
        self.t.XTestFakeButtonEvent(self.dpy, 1, 0, 0)
        self.x.XFlush(self.dpy)


def wv_targets(port):
    """Office's pages, or None when its DevTools port does not answer."""
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/json/list" % port, timeout=1) as r:
            return [t for t in json.load(r) if t.get("type") == "page"]
    except (OSError, ValueError):
        return None


class Hub:
    """What the page shows, and the newest frame for a remote screen."""

    def __init__(self, device, mode, email):
        self.cv = threading.Condition()
        self.ver = 0
        self.state = {"step": "email", "device": device, "mode": mode, "email": email or "", "busy": False, "message": ""}
        self.frame = None
        self.fver = 0
        self.inbox = queue.Queue()

    def set(self, **kw):
        with self.cv:
            self.state.update(kw)
            self.ver += 1
            self.cv.notify_all()

    def put_frame(self, data, w, h):
        with self.cv:
            self.frame = {"img": data, "w": w, "h": h}
            self.fver += 1
            self.cv.notify_all()


def serve(hub, sid, sock, remote_input):
    page = open(os.path.join(HERE, "index.html"), "rb").read()
    csp = ("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; "
           "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")

    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def allowed(self):
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            given = self.headers.get("X-Session") or (q.get("s") or [""])[0]
            return hmac.compare_digest(given.encode(), sid.encode())

        def reply(self, code, body, ctype="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Referrer-Policy", "no-referrer")
            if ctype.startswith("text/html"):
                self.send_header("Content-Security-Policy", csp)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urllib.parse.urlsplit(self.path).path
            if path == "/":
                self.reply(200, page, "text/html; charset=utf-8")
                return
            if path != "/events" or not self.allowed():
                self.reply(404, b"{}")
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            ver = fver = -1
            try:
                while True:
                    with hub.cv:
                        hub.cv.wait_for(lambda: hub.ver != ver or hub.fver != fver, timeout=15)
                        state, sv = dict(hub.state), hub.ver
                        frame, fv = hub.frame, hub.fver
                    out = b""
                    if sv != ver:
                        out += b"event: state\ndata: " + json.dumps(state).encode() + b"\n\n"
                        ver = sv
                    if fv != fver and frame:
                        out += b"event: frame\ndata: " + json.dumps(frame).encode() + b"\n\n"
                        fver = fv
                    self.wfile.write(out or b": keep\n\n")
                    self.wfile.flush()
            except OSError:
                return

        def do_POST(self):
            # The body is read before the session is checked: one left unread
            # on a kept-alive connection would be parsed as the next request.
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                n = -1
            if not 0 <= n <= 65536:
                self.close_connection = True
                self.reply(413 if n > 0 else 400, b"{}")
                return
            data = self.rfile.read(n)
            if urllib.parse.urlsplit(self.path).path != "/api" or not self.allowed():
                self.reply(404, b"{}")
                return
            try:
                msg = json.loads(data or b"{}")
            except ValueError:
                msg = None
            if not isinstance(msg, dict):
                self.reply(400, b"{}")
                return
            if msg.get("t") in ("email", "choose", "cancel"):
                hub.inbox.put(msg)
                self.reply(200, b"{}")
            elif remote_input:
                try:
                    self.reply(200, json.dumps(remote_input(msg) or {}).encode())
                except (CDPError, KeyError, ValueError, TypeError):
                    self.reply(400, b"{}")
            else:
                self.reply(200, b"{}")

    class S(http.server.ThreadingHTTPServer):
        daemon_threads = True

    srv = S(sock.getsockname()[:2], H, bind_and_activate=False)
    srv.socket.close()
    srv.socket = sock
    sock.listen(16)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class Browser:
    """Chromium with its own short-lived profile in memory, driven over a pipe."""

    def __init__(self, binary, url, remote, profile):
        r_in, w_in = os.pipe()
        r_out, w_out = os.pipe()
        lang = os.environ.get("LANG", "").split(".")[0].replace("_", "-") or "en-US"
        args = [binary, "--user-data-dir=" + profile, "--remote-debugging-pipe",
                "--no-first-run", "--no-default-browser-check", "--disable-sync",
                "--password-store=basic", "--disable-features=Translate,MediaRouter",
                "--class=omarchohard-signin", "--lang=" + lang]
        if remote:
            args += ["--headless=new", "--hide-scrollbars", "--mute-audio", "--window-size=420,820", "about:blank"]
        else:
            args += ["--window-size=460,700", "--app=" + url]

        def fds():
            os.dup2(r_in, 3)
            os.dup2(w_out, 4)
            os.setsid()

        self.proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, pass_fds=(3, 4), preexec_fn=fds)
        os.close(r_in)
        os.close(w_out)
        self.cdp = pipe_cdp(r_out, w_in)
        self.session = None

    def attach(self, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            for t in self.cdp.call("Target.getTargets")["targetInfos"]:
                if t["type"] == "page":
                    self.session = self.cdp.call("Target.attachToTarget", {"targetId": t["targetId"], "flatten": True})["sessionId"]
                    return self.session
            time.sleep(0.1)
        raise CDPError("the sign-in window did not open")

    def call(self, method, params=None, timeout=20):
        return self.cdp.call(method, params, self.session, timeout)

    def close(self):
        if self.proc.poll() is None:
            try:
                self.cdp.call("Browser.close", timeout=3)
            except CDPError:
                pass
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGKILL)


class Office:
    """Office's sign-in window: WebView2 under Wine, on the hidden screen."""

    def __init__(self, port, display, pid=0):
        self.port = port
        self.display = display
        self.pid = pid
        self.start_url = None
        self.cdp = None
        self.authorize = None
        self.got_authorize = threading.Event()

    def open_signin(self, deadline):
        """Word's first window, then a click on its sign-in button, until the
        WebView2 page answers."""
        x11 = X11(self.display)
        clicked = 0.0
        while time.time() < deadline:
            pages = [t for t in wv_targets(self.port) or [] if "officeapps.live.com" in t.get("url", "")]
            if pages:
                return pages[0]
            if time.time() - clicked > 6:
                w = x11.find("Sign in to set up Office")
                if w:
                    x, y, _ww, hh = x11.rect(w)
                    # "Sign in or create account": left column, near the bottom.
                    x11.click(x + 136, y + hh - 185)
                    clicked = time.time()
            time.sleep(0.25)
        raise CDPError("Office's sign-in window did not open")

    def connect(self, target):
        self.start_url = target["url"]
        self.cdp = ws_cdp(target["webSocketDebuggerUrl"])

        def paused(p, _s):
            self.cdp.call("Fetch.failRequest", {"requestId": p["requestId"], "errorReason": "Aborted"})
            if not self.authorize:
                self.authorize = p["request"]["url"]
                self.got_authorize.set()

        self.cdp.on("Fetch.requestPaused", paused)
        self.cdp.call("Fetch.enable", {"patterns": [{"urlPattern": AUTHORIZE, "requestStage": "Request"}]})

    def alive(self):
        """Word is still running (no pid given: assume so)."""
        if not self.pid:
            return True
        try:
            os.kill(self.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def back_to_email(self):
        """Office's window back on its email page, for another address."""
        self.cdp.call("Page.navigate", {"url": self.start_url})
        time.sleep(0.5)

    def js(self, expr):
        r = self.cdp.call("Runtime.evaluate", {"expression": expr, "returnByValue": True})
        return r.get("result", {}).get("value")

    def text(self):
        return self.js("document.body ? document.body.innerText : ''") or ""

    FIELD = "document.querySelector('input[type=email],input[name=loginfmt],input[type=text]')"

    def enter_email(self, email, deadline):
        """Type the address and press Next. A page still starting up reloads
        and drops what was typed, so wait for it to settle and retry once."""
        for _attempt in range(3):
            while time.time() < deadline:
                if self.js("document.readyState==='complete'&&!!%s" % self.FIELD):
                    break
                time.sleep(0.2)
            else:
                raise CDPError("Office's email page did not load")
            time.sleep(0.6)
            self.js("(i=>{i.focus();i.select()})(%s)" % self.FIELD)
            self.cdp.call("Input.insertText", {"text": email})
            if not self.click_at("document.querySelector('input[type=submit],button[type=submit]')") \
                    and not self.click_text("Next"):
                for kind in ("keyDown", "keyUp"):
                    p = {"type": kind, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13}
                    if kind == "keyDown":
                        p["text"] = "\r"
                    self.cdp.call("Input.dispatchKeyEvent", p)
            end = time.time() + 4
            while time.time() < end:
                time.sleep(0.3)
                if self.got_authorize.is_set():
                    return
                field = self.js("(i=>!i?'gone':i.value===''?'empty':'typed')(%s)" % self.FIELD)
                if field == "gone":
                    return
                if field == "empty":
                    break
            else:
                return

    def click_text(self, label):
        return self.click_at("(()=>{const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);"
                             "while(w.nextNode()){if(w.currentNode.nodeValue.trim()===%s)"
                             "return w.currentNode.parentElement}return null})()" % json.dumps(label))

    def click_at(self, element_expr):
        """A real mouse click in the middle of the element, as a person would."""
        r = self.js("(e=>{if(!e)return null;const r=e.getBoundingClientRect();"
                    "return [r.x+r.width/2,r.y+r.height/2,r.width]})(%s)" % element_expr)
        if not r or not r[2]:
            return False
        for kind in ("mousePressed", "mouseReleased"):
            self.cdp.call("Input.dispatchMouseEvent", {"type": kind, "x": r[0], "y": r[1], "button": "left", "clickCount": 1})
        return True

    def finish(self, answer, timeout=45):
        """Hand Microsoft's answer to Office and wait for its verdict: the
        sign-in window closes, or an error page says why not."""
        try:
            self.cdp.call("Page.navigate", {"url": answer}, timeout=10)
        except CDPError:
            pass  # Office cancels the navigation itself once it has the code
        end = time.time() + timeout
        quiet = None
        seen = set()
        while time.time() < end:
            if not self.alive():
                return False, "Office closed before it finished signing in"
            pages = wv_targets(self.port)
            for t in pages or []:
                where = t.get("url", "").split("?")[0].split("#")[0][:120]
                if where not in seen:
                    seen.add(where)
                    log("Office shows: " + where)
            msg = self.error_text(pages or [])
            if msg:
                return False, msg
            # No sign-in page left (or the window's browser has exited),
            # with Word still running: Office has taken the sign-in.
            if not [t for t in pages or [] if t.get("url", "").startswith("http")]:
                quiet = quiet or time.time()
                if time.time() - quiet > 6:
                    return True, ""
            else:
                quiet = None
            time.sleep(0.5)
        return False, "Office did not finish signing in"

    @staticmethod
    def error_text(pages):
        for t in pages:
            try:
                c = ws_cdp(t["webSocketDebuggerUrl"])
                r = c.call("Runtime.evaluate", {"expression": "document.body ? document.body.innerText : ''",
                                                "returnByValue": True}, timeout=3)
                c.sock.close()
                text = r.get("result", {}).get("value") or ""
            except (CDPError, OSError, KeyError):
                continue
            if "Something went wrong" in text or "Troubleshooting details" in text:
                for line in text.splitlines():
                    if line.startswith("Message:"):
                        return line[len("Message:"):].strip()
                return "Office reported an error"
        return ""


def wait_inbox(hub, browser, deadline, kinds):
    while time.time() < deadline:
        if browser.proc.poll() is not None:
            raise CDPError("the sign-in window was closed")
        try:
            msg = hub.inbox.get(timeout=0.25)
        except queue.Empty:
            continue
        if msg.get("t") == "cancel":
            raise CDPError("cancelled")
        if msg.get("t") in kinds:
            return msg
    raise CDPError("the sign-in timed out")


def pick_account(hub, browser, office, deadline):
    """After the email: Microsoft's request, or Office asking whether the
    address is a work or a personal account (some are both)."""
    end = time.time() + 25
    while time.time() < end:
        if office.got_authorize.wait(0.3):
            return "ok"
        text = office.text()
        if "Work or school account" in text and "Personal account" in text:
            hub.set(step="choose", busy=False, message="")
            msg = wait_inbox(hub, browser, deadline, ("choose", "email"))
            if msg["t"] == "email":
                return "retry"
            hub.set(step="choose", busy=True)
            office.click_text("Work or school account" if msg.get("v") == "work" else "Personal account")
            if office.got_authorize.wait(20):
                return "ok"
            break
    hub.set(step="email", busy=False, email="",
            message="Microsoft did not find an account for that address. Check it and try again.")
    return "retry"


def watch_answer(browser, answer, caught):
    """Catch Microsoft's answer in the real browser before it goes anywhere:
    the redirect to the urn, or the personal-account desktop page."""
    cdp = browser.cdp

    def paused(p, s):
        url = p["request"]["url"]
        found = None
        if url.startswith(DESKTOP) and "code=" in url:
            found = url
        elif p.get("responseStatusCode") in (301, 302, 303, 307, 308):
            for h in p.get("responseHeaders") or []:
                if h["name"].lower() == "location" and h["value"].startswith(OOB):
                    found = h["value"]
        if found and not caught.is_set():
            answer["url"] = found
            caught.set()
            cdp.call("Fetch.failRequest", {"requestId": p["requestId"], "errorReason": "Aborted"}, s)
        else:
            cdp.call("Fetch.continueRequest", {"requestId": p["requestId"]}, s)

    cdp.on("Fetch.requestPaused", paused)
    browser.call("Fetch.enable", {"patterns": [
        {"urlPattern": "https://login.microsoftonline.com/*", "requestStage": "Response"},
        {"urlPattern": "https://login.microsoft.com/*", "requestStage": "Response"},
        {"urlPattern": "https://login.live.com/*", "requestStage": "Response"},
        {"urlPattern": DESKTOP + "*", "requestStage": "Request"},
    ]})


class Remote:
    """The headless browser shown on another device: frames out, taps and
    keys in. The page is laid out for that device's screen."""

    KEYS = {"Backspace": 8, "Tab": 9, "Enter": 13, "Escape": 27, "ArrowLeft": 37, "ArrowRight": 39, "Delete": 46}

    def __init__(self, browser, hub):
        self.b = browser
        self.hub = hub
        self.size = None
        self.scale = (1.0, 1.0)  # viewer's CSS pixels to the browser's
        browser.cdp.on("Page.screencastFrame", self.frame)
        browser.call("Page.enable")

    def frame(self, p, s):
        self.b.cdp.call("Page.screencastFrameAck", {"sessionId": p["sessionId"]}, s)
        m = p["metadata"]
        self.hub.put_frame(p["data"], m["deviceWidth"], m["deviceHeight"])

    def input(self, msg):
        t = msg.get("t")
        call = self.b.call
        if t == "viewport":
            vw, vh = max(1, int(msg.get("w", 400))), max(1, int(msg.get("h", 800)))
            w, h = max(280, min(vw, 1200)), max(400, min(vh, 1600))
            self.scale = (w / vw, h / vh)
            dpr = max(1.0, min(float(msg.get("dpr", 2)), 2.0))
            dark = bool(msg.get("dark"))
            if self.size != (w, h, dpr, dark):
                self.size = (w, h, dpr, dark)
                call("Emulation.setEmulatedMedia", {"features": [{"name": "prefers-color-scheme", "value": "dark" if dark else "light"}]})
                call("Emulation.setDeviceMetricsOverride", {"width": w, "height": h, "deviceScaleFactor": dpr, "mobile": w < 700})
                call("Page.stopScreencast")
                call("Page.startScreencast", {"format": "jpeg", "quality": 80, "maxWidth": int(w * dpr), "maxHeight": int(h * dpr)})
            return {}
        if t == "tap":
            for kind in ("mousePressed", "mouseReleased"):
                call("Input.dispatchMouseEvent", {"type": kind, "x": float(msg["x"]) * self.scale[0], "y": float(msg["y"]) * self.scale[1],
                                                  "button": "left", "clickCount": 1})
            time.sleep(0.05)
            r = call("Runtime.evaluate", {"expression": "(()=>{const e=document.activeElement;return !!e&&(e.isContentEditable||"
                                                        "e.tagName==='TEXTAREA'||(e.tagName==='INPUT'&&"
                                                        "!/^(button|submit|checkbox|radio)$/.test(e.type)))})()",
                                          "returnByValue": True})
            return {"editable": bool(r.get("result", {}).get("value"))}
        if t == "wheel":
            call("Input.dispatchMouseEvent", {"type": "mouseWheel", "x": float(msg.get("x", 10)) * self.scale[0],
                                              "y": float(msg.get("y", 10)) * self.scale[1],
                                              "deltaX": 0, "deltaY": float(msg.get("dy", 0))})
            return {}
        if t == "text":
            call("Input.insertText", {"text": str(msg.get("s", ""))[:2000]})
            return {}
        if t == "key" and msg.get("k") in self.KEYS:
            k = msg["k"]
            for kind in ("rawKeyDown", "keyUp"):
                call("Input.dispatchKeyEvent", {"type": kind, "key": k, "code": k, "windowsVirtualKeyCode": self.KEYS[k]})
            if k == "Enter":
                call("Input.dispatchKeyEvent", {"type": "char", "key": "Enter", "text": "\r", "windowsVirtualKeyCode": 13})
            return {}
        return {}


def run(a, hub, browser, office, url, remote, deadline):
    # Office starts while the person types, so its sign-in page is ready by then.
    opened = {}

    def start_office():
        try:
            office.connect(office.open_signin(deadline))
            opened["ok"] = True
        except (CDPError, OSError) as e:
            opened["err"] = str(e)

    starter = threading.Thread(target=start_office, daemon=True)
    starter.start()
    answer = {}
    caught = threading.Event()
    watch_answer(browser, answer, caught)

    email = a.email
    retry = False
    while True:
        if not email:
            hub.set(step="email", busy=False)
            email = (wait_inbox(hub, browser, deadline, ("email",)).get("v") or "").strip()
            if "@" not in email:
                email = ""
                continue
        hub.set(step="email", email=email, busy=True, message="")
        starter.join(max(0, deadline - time.time()))
        if not opened.get("ok"):
            raise CDPError(opened.get("err") or "Office's sign-in window did not open")
        if retry:
            office.back_to_email()
        office.enter_email(email, time.time() + 30)
        if pick_account(hub, browser, office, deadline) == "ok":
            break
        email = ""
        retry = True

    hub.set(step="microsoft", busy=False)
    browser.call("Page.navigate", {"url": office.authorize})
    while not caught.wait(0.25):
        if time.time() > deadline:
            raise CDPError("the sign-in timed out")
        if browser.proc.poll() is not None:
            log("the sign-in window was closed")
            return 3
    if not remote:
        browser.call("Page.navigate", {"url": url})
    hub.set(step="finishing")
    ok, why = office.finish(answer["url"])
    if ok:
        hub.set(step="done")
        log("signed in")
        return 0
    hub.set(step="error", message=why)
    log("Office did not accept the sign-in: " + why)
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--office-port", type=int, required=True, help="Office's WebView2 DevTools port")
    ap.add_argument("--display", required=True, help="the hidden screen Word is on")
    ap.add_argument("--browser", required=True, help="a Chromium-family browser")
    ap.add_argument("--remote", metavar="IP:PORT", help="serve the sign-in to another device")
    ap.add_argument("--session-file", help="the link's session id, read once and removed")
    ap.add_argument("--ready-file", help="written once the page answers")
    ap.add_argument("--email", default="")
    ap.add_argument("--device", default=socket.gethostname())
    ap.add_argument("--minutes", type=int, default=30)
    ap.add_argument("--office-pid", type=int, default=0, help="Word's process, to tell a crash from a finished sign-in")
    a = ap.parse_args()

    deadline = time.time() + a.minutes * 60
    sid = secrets.token_urlsafe(24)
    if a.session_file:
        with open(a.session_file) as f:
            sid = f.read().strip()
        os.unlink(a.session_file)
    remote = bool(a.remote)
    host, port = a.remote.rsplit(":", 1) if remote else ("127.0.0.1", "0")
    host = host.strip("[]")
    sock = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, int(port)))
    url = "http://127.0.0.1:%d/#s=%s" % (sock.getsockname()[1], sid)

    hub = Hub(a.device, "remote" if remote else "local", a.email)
    # Serving before the browser starts: the local window opens this page
    # first thing. Remote input waits for the browser (a 400 until then).
    inputs = {}
    serve(hub, sid, sock, (lambda msg: inputs["fn"](msg)) if remote else None)
    profile = tempfile.mkdtemp(prefix="omarchohard-signin-", dir=os.environ.get("XDG_RUNTIME_DIR") or None)
    browser = Browser(a.browser, url, remote, profile)
    office = Office(a.office_port, a.display, a.office_pid)
    rc = 1
    stopped = []

    def stop(signum, _frame):
        stopped.append(signum)
        sys.exit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, stop)
    try:
        browser.attach()
        if remote:
            inputs["fn"] = Remote(browser, hub).input
        if a.ready_file:
            with open(a.ready_file, "w") as f:
                f.write("ready\n")
        rc = run(a, hub, browser, office, url, remote, deadline)
    except CDPError as e:
        log(str(e))
        hub.set(step="error", message=str(e)[:1].upper() + str(e)[1:] + ".")
    finally:
        if browser.proc.poll() is None and not stopped:
            time.sleep(4 if rc == 0 else 2)  # time to read the result
        browser.close()
        shutil.rmtree(profile, ignore_errors=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
