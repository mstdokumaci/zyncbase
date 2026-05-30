FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies for Zig, OpenSSL, and uWebSockets
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    git \
    build-essential \
    libssl-dev \
    python3 \
    libsqlite3-dev \
    gdb \
    strace \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# Install Zig 0.15.2
RUN curl -L https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz | tar -xJ -C /usr/local
RUN ln -s /usr/local/zig-x86_64-linux-0.15.2/zig /usr/bin/zig

WORKDIR /app

ENTRYPOINT ["zig"]
