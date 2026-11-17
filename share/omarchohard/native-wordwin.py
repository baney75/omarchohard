# Whether a hidden resident Word holds a document: native-wordwin.py PID.
#
# Exit 0 when one of PID's X windows, mapped or not, is titled
# "NAME - Microsoft Word" or "NAME - Word"; 1 when none is; 2 when that
# cannot be told (no X display in PID's environment, no libX11, an error).
# omarchohard counts 2 as in use, so only a clear 1 lets a Word be closed.
#
# A fresh resident (WINWORD.EXE /Automation -Embedding) has helper windows
# and one unmapped window titled exactly "Microsoft Word", which does not
# count. While it shows a document it also has "Document1 - Microsoft Word",
# which goes when the document closes. Wine's tasklist shows no titles, so
# this asks the X server: winex11 sets _NET_WM_PID to the Unix pid.
#
# Run with python3 -I. Reads only PID's environment (for DISPLAY and
# XAUTHORITY) and the X server's window tree.
import ctypes
import ctypes.util
import os
import re
import sys

WORD_TITLE = re.compile(r"\s-\s(Microsoft\s)?Word$")
XA_CARDINAL = 6


def word_window(pid):
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            raw = f.read().decode("utf-8", "replace")
    except OSError:
        return 2
    env = dict(item.split("=", 1) for item in raw.split("\0") if "=" in item)
    if not env.get("DISPLAY"):
        return 2
    if env.get("XAUTHORITY"):
        os.environ["XAUTHORITY"] = env["XAUTHORITY"]
    lib = ctypes.util.find_library("X11")
    if not lib:
        return 2
    x = ctypes.cdll.LoadLibrary(lib)
    W = ctypes.c_ulong

    # Xlib's own handlers print and exit 1, which would read as "no Word
    # window". A window that closes mid-walk is skipped; a lost connection
    # is unknown.
    error_handler = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
    io_error_handler = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
    on_error = error_handler(lambda d, e: 0)
    on_io_error = io_error_handler(lambda d: os._exit(2))
    x.XSetErrorHandler.argtypes = [error_handler]
    x.XSetErrorHandler.restype = ctypes.c_void_p
    x.XSetIOErrorHandler.argtypes = [io_error_handler]
    x.XSetIOErrorHandler.restype = ctypes.c_void_p
    x.XSetErrorHandler(on_error)
    x.XSetIOErrorHandler(on_io_error)

    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    d = x.XOpenDisplay(env["DISPLAY"].encode())
    if not d:
        return 2
    x.XDefaultRootWindow.restype = W
    x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x.XInternAtom.restype = W
    x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x.XQueryTree.argtypes = [ctypes.c_void_p, W, ctypes.POINTER(W), ctypes.POINTER(W),
                             ctypes.POINTER(ctypes.POINTER(W)), ctypes.POINTER(ctypes.c_uint)]
    x.XGetWindowProperty.argtypes = [ctypes.c_void_p, W, W, ctypes.c_long, ctypes.c_long, ctypes.c_int, W,
                                     ctypes.POINTER(W), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong),
                                     ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p)]
    x.XFree.argtypes = [ctypes.c_void_p]
    net_wm_pid, net_wm_name, utf8 = (x.XInternAtom(d, n, 0) for n in (b"_NET_WM_PID", b"_NET_WM_NAME", b"UTF8_STRING"))

    def prop(w, atom, typ):
        t, fmt, n, after, p = W(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p()
        if x.XGetWindowProperty(d, w, atom, 0, 1024, 0, typ, ctypes.byref(t), ctypes.byref(fmt), ctypes.byref(n),
                                ctypes.byref(after), ctypes.byref(p)) != 0 or not p.value:
            return None
        try:
            if fmt.value == 32:
                return ctypes.cast(p, ctypes.POINTER(ctypes.c_long))[0] if n.value else None
            return ctypes.string_at(p, n.value).decode("utf-8", "replace")
        finally:
            x.XFree(p)

    def walk(w):
        root, parent, kids, n = W(), W(), ctypes.POINTER(W)(), ctypes.c_uint()
        if not x.XQueryTree(d, w, ctypes.byref(root), ctypes.byref(parent), ctypes.byref(kids), ctypes.byref(n)):
            return
        ids = [kids[i] for i in range(n.value)]
        if kids:
            x.XFree(kids)
        for c in ids:
            yield c
            yield from walk(c)

    for w in walk(x.XDefaultRootWindow(d)):
        if prop(w, net_wm_pid, XA_CARDINAL) == pid and WORD_TITLE.search(prop(w, net_wm_name, utf8) or ""):
            return 0
    return 1


def main():
    try:
        pid = int(sys.argv[1])
        code = word_window(pid)
    except BaseException:
        code = 2
    sys.exit(code)


if __name__ == "__main__":
    main()
