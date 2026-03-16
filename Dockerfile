FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies for Zig, BoringSSL, and uWebSockets
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    git \
    build-essential \
    cmake \
    ninja-build \
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

WORKDIR /build
# Copy the entire boringssl directory
COPY vendor/boringssl/ /build/boringssl/
RUN mkdir -p /build/boringssl/build-linux && \
    cd /build/boringssl/build-linux && \
    cmake -GNinja -DCMAKE_BUILD_TYPE=Release .. && \
    ninja crypto ssl decrepit

WORKDIR /app

# The project volume will be mounted at /app.
# Provide the environment variable to let build.zig know where the cached BoringSSL libs are located.
# Now ../include will resolve to /build/boringssl/include correctly.
ENV ZYNCBASE_LINUX_BORINGSSL_PATH="/build/boringssl/build-linux"

ENTRYPOINT ["zig"]
