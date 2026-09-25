FROM azul/zulu-openjdk:6

# The image ships an azulsystems.com apt source for installing other
# Zulu packages; its HTTPS cert check fails on this minimal base
# (no ca-certificates yet) and we don't need more Zulu packages anyway.
RUN rm -f /etc/apt/sources.list.d/*azul* /etc/apt/sources.list.d/*zulu*

RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb \
    x11vnc \
    fluxbox \
    novnc \
    websockify \
    python3 \
    python3-pip \
    xfonts-base \
    xfonts-75dpi \
    xfonts-100dpi \
    fonts-dejavu-core \
    fontconfig \
    curl \
    && pip3 install --no-cache-dir requests \
    && rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/appletviewer appletviewer /usr/lib/jvm/zulu-6-amd64/bin/appletviewer 1 || true
ENV PATH="/usr/lib/jvm/zulu-6-amd64/bin:${PATH}"

WORKDIR /opt/shim
COPY java6-test/login_and_launch.py /opt/shim/login_and_launch.py
COPY java6-test/entrypoint.sh /opt/shim/entrypoint.sh
RUN chmod +x /opt/shim/entrypoint.sh

# Reuse the same permissive AllPermission grant as the Java 8 setup --
# still needed regardless of JVM vintage for raw-socket + AWT access.
COPY security/all.policy /opt/shim/security/all.policy

# Same bm.class patch as the main image (see patch/nn/pp/rc/bm.java),
# compiled fresh with THIS JVM's own javac so the bytecode version is
# guaranteed Java-6-loadable.
COPY java6-test/patch/ /opt/shim/patch-src/
RUN mkdir -p /opt/shim/patch-classes && \
    javac -d /opt/shim/patch-classes /opt/shim/patch-src/nn/pp/rc/bm.java

RUN mkdir -p /work
WORKDIR /work

EXPOSE 5901 6081

ENTRYPOINT ["/opt/shim/entrypoint.sh"]
