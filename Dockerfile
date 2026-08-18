FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies for Zig, OpenSSL, and TSAN
# (llvm provides llvm-objcopy for the libc++ workaround and llvm-symbolizer for
# TSAN reports, as binutils addr2line cannot parse Zig's DWARF)
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    libssl-dev \
    unzip \
    llvm \
    && rm -rf /var/lib/apt/lists/*

# Install Bun (pinned, checksum verified; mirrors the install script layout)
# SHA-256 computed from the upstream release asset.
RUN curl -fsSL --retry 5 --retry-delay 5 -o /tmp/bun.zip \
        "https://github.com/oven-sh/bun/releases/download/bun-v1.3.11/bun-linux-x64.zip" \
    && echo "8611ba935af886f05a6f38740a15160326c15e5d5d07adef966130b4493607ed  /tmp/bun.zip" | sha256sum -c - \
    && unzip -d /usr/local /tmp/bun.zip \
    && ln -s /usr/local/bun-linux-x64/bun /usr/local/bin/bun \
    && rm /tmp/bun.zip

# Install Zig 0.16.0
RUN curl -L https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz | tar -xJ -C /usr/local
RUN ln -s /usr/local/zig-x86_64-linux-0.16.0/zig /usr/bin/zig

WORKDIR /app

# LLVM's symbolizer can parse Zig 0.16 DWARF; binutils addr2line cannot
# ("unknown format content type 8193"), so TSAN reports would be unreadable.
ENV TSAN_OPTIONS="second_deadlock_stack=1:history_size=7:external_symbolizer_path=/usr/lib/llvm-18/bin/llvm-symbolizer"

# Runs TSAN prep (zig libc++ guard-symbol workaround) before tsan builds.
# The repo must be mounted at /app.
ENTRYPOINT ["/app/scripts/docker-entrypoint.sh"]
