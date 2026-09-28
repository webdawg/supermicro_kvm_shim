FROM eclipse-temurin:8-jdk

RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb \
    x11vnc \
    fluxbox \
    novnc \
    websockify \
    python3 \
    python3-requests \
    xfonts-base \
    xfonts-75dpi \
    xfonts-100dpi \
    fonts-dejavu-core \
    fontconfig \
    ipmitool \
    procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/shim
COPY login_and_launch.py /opt/shim/login_and_launch.py
COPY reset_server.py /opt/shim/reset_server.py
COPY security/ /opt/shim/security/
COPY entrypoint.sh /opt/shim/entrypoint.sh
RUN chmod +x /opt/shim/entrypoint.sh

# Landing page: "Connect" forces a fresh BMC login + applet relaunch
# (see reset_server.py) before handing off to noVNC's own vnc.html.
COPY connect.html /usr/share/novnc/connect.html
COPY index.html /usr/share/novnc/index.html

COPY tools/bmc-tools.sh /usr/local/bin/bmc-tools.sh
RUN chmod +x /usr/local/bin/bmc-tools.sh

# Pre-compiled replacement for nn.pp.rc.bm: the original class nulls
# out its owning PopupMenu's label, which trips a null-label bug in
# sun.awt.X11.XPopupMenuPeer.getCaptionSize() on every click, crashing
# the click handler before it can hand focus to the console canvas.
# See patch/nn/pp/rc/bm.java for the full rationale.
COPY patch/ /opt/shim/patch-src/
RUN mkdir -p /opt/shim/patch-classes && \
    javac -d /opt/shim/patch-classes /opt/shim/patch-src/nn/pp/rc/bm.java

RUN mkdir -p /work
WORKDIR /work

EXPOSE 5900 6080

ENTRYPOINT ["/opt/shim/entrypoint.sh"]
