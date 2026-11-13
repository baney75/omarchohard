# The hidden screen for `omarchohard native signin --remote`: Xvfb, a VNC
# server on it and omarchohard's sign-in page, which shows it through
# noVNC's core (no noVNC interface). Also the seed server's Python for
# `native seed serve` on a machine without python3. Word runs on the host
# and draws on this screen through the socket folder the host mounts at
# /tmp/.X11-unix. Only the page's port leaves the container, and the host
# publishes it on the tailnet (or LAN) address only.
FROM alpine:3.24
# websockify is the Python package (py3-websockify in older releases).
RUN apk add --no-cache xvfb x11vnc novnc websockify xwininfo && \
  mkdir -p /usr/local/share/omarchohard/web && \
  ln -s /usr/share/novnc/core /usr/local/share/omarchohard/web/core && \
  ln -s /usr/share/novnc/vendor /usr/local/share/omarchohard/web/vendor
COPY index.html /usr/local/share/omarchohard/web/index.html
COPY entry.sh /usr/local/bin/omarchohard-remote
COPY seed-serve.py /usr/local/share/omarchohard/seed-serve.py
ENTRYPOINT ["/bin/sh", "/usr/local/bin/omarchohard-remote"]
