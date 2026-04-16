# =============================================================================
# Multi-stage Dockerfile for building v8dasm as a Linux binary
# Targets V8 version 9.4.146.24
#
# WARNING: Building V8 from source requires ~30GB disk and takes 1-2 hours.
# Make sure Docker has enough disk space allocated.
#
# Usage:
#   docker build -t v8dasm-builder .
#   docker run --rm v8dasm-builder > v8dasm        # extract binary
#   chmod +x v8dasm
#
# Or use the convenience script: ./docker-build.sh
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build V8 and the disassembler
# ---------------------------------------------------------------------------
FROM ubuntu:20.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    git curl wget python3 python3-pip lsb-release sudo \
    build-essential cmake pkg-config ninja-build \
    libglib2.0-dev \
    && rm -rf /var/lib/apt/lists/*

# Install depot_tools
RUN git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git /opt/depot_tools
ENV PATH="/opt/depot_tools:${PATH}"

# Configure git (required by depot_tools)
RUN git config --global user.email "build@docker" && \
    git config --global user.name "Docker Build"

# Fetch V8 source — this downloads several GB (version-independent, stays cached)
WORKDIR /build/v8
RUN fetch v8

# --- Everything below here rebuilds when V8_VERSION changes ---
ENV V8_VERSION=9.4.146.24

# Checkout target version and sync dependencies
WORKDIR /build/v8/v8
RUN git checkout refs/tags/${V8_VERSION}
RUN gclient sync -D

# Copy and apply patches for disassembly output
COPY patches/apply-v8-patches.sh /build/patches/apply-v8-patches.sh
RUN chmod +x /build/patches/apply-v8-patches.sh && \
    /build/patches/apply-v8-patches.sh /build/v8/v8

# Configure V8 build
RUN mkdir -p out/x64.release && \
    cat > out/x64.release/args.gn <<'EOF'
is_debug = false
target_cpu = "x64"
v8_enable_backtrace = true
v8_enable_slow_dchecks = false
v8_optimized_debug = false
is_component_build = false
v8_static_library = true
v8_enable_disassembler = true
v8_enable_object_print = true
use_custom_libcxx = false
v8_use_external_startup_data = false
treat_warnings_as_errors = false
EOF

# Generate build files and build V8
RUN gn gen out/x64.release
RUN ninja -C out/x64.release wee8 v8_libbase v8_libplatform

# ---------------------------------------------------------------------------
# Build the disassembler
# ---------------------------------------------------------------------------
WORKDIR /build/v8dasm
COPY v8dasm.cpp .
COPY CMakeLists.txt .

# Create symlink so CMakeLists.txt can find V8
RUN ln -s /build/v8 ./v8

# Build v8dasm
RUN cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DV8_OUT_DIR=/build/v8/v8/out/x64.release \
    && cmake --build build --verbose

# Verify the binary works
RUN ldd build/v8dasm || true
RUN build/v8dasm --help 2>&1 || true

# ---------------------------------------------------------------------------
# Stage 2: Minimal image with just the binary
# ---------------------------------------------------------------------------
FROM ubuntu:20.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/v8dasm/build/v8dasm /usr/local/bin/v8dasm

ENTRYPOINT ["v8dasm"]
