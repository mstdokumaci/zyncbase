# Building ZyncBase

> [!NOTE]
> ZyncBase is licensed under the [Business Source License 1.1](LICENSE). Source code is available, but production use as a managed service is restricted until 2032-01-01.

## Prerequisites

### Required Tools

1. **Zig** (0.13.0 or later)
   - Download from https://ziglang.org/download/

2. **CMake** (3.10 or later)
   - macOS: `brew install cmake`
   - Linux: `sudo apt-get install cmake`
   - Windows: Download from https://cmake.org/download/

3. **Go** (1.18 or later) - Required by BoringSSL build
   - macOS: `brew install go`
   - Linux: `sudo apt-get install golang`
   - Windows: Download from https://golang.org/dl/

4. **C/C++ Compiler**
   - macOS: Xcode Command Line Tools (`xcode-select --install`)
   - Linux: GCC or Clang (`sudo apt-get install build-essential`)
   - Windows: Visual Studio or MinGW

## Build Steps

### 1. Clone Repository with Submodules

```bash
git clone --recursive https://github.com/your-org/zyncbase.git
cd zyncbase
```

If you already cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

### 2. Apply Patches to Bun's uWebSockets

Bun's uWebSockets fork includes several dependencies we don't need (like libdeflate and SIMDUTF). We use minimal patches to disable them and stub functions for Bun-specific runtime hooks.

```bash
./scripts/apply-patches.sh
```

For detailed technical information about the patches and stubs, see [patches.md](specs/implementation/patches.md).

### 3. Build BoringSSL

BoringSSL must be built before building ZyncBase:

```bash
./scripts/build-boringssl.sh
```

This will:
- Configure BoringSSL with CMake
- Build static libraries (`libssl.a` and `libcrypto.a`)
- Place build artifacts in `vendor/boringssl/build/`

**Note:** This step only needs to be done once, or when updating the BoringSSL submodule.

### 3. Build ZyncBase

```bash
zig build
```

The executable will be created at `./zig-out/bin/zyncbase`.

### 4. Run Tests

```bash
zig build test
```

## Build Options

### Debug Build (default)

```bash
zig build
```

### Release Build

```bash
zig build -Doptimize=ReleaseFast
```

### With Sanitizers

```bash
# Thread sanitizer
zig build -Dsanitize=thread

# Address sanitizer (if supported)
zig build -Dsanitize=address
```

## Troubleshooting

### CMake Not Found

```
Error: cmake is not installed
```

**Solution:** Install CMake using your package manager (see Prerequisites).

### Go Not Found

```
Error: Go is required to build BoringSSL
```

**Solution:** Install Go using your package manager (see Prerequisites).

### BoringSSL Build Fails

```
Error: BoringSSL build failed
```

**Solution:**
1. Ensure all prerequisites are installed
2. Try cleaning and rebuilding:
   ```bash
   rm -rf vendor/boringssl/build
   ./scripts/build-boringssl.sh
   ```

### Submodule Not Initialized

```
Error: vendor/bun/packages/bun-uws/src not found
```

**Solution:**
```bash
git submodule update --init --recursive
```

## Development Workflow

### Clean Build

```bash
rm -rf zig-out zig-cache
zig build
```

### Rebuild BoringSSL

```bash
rm -rf vendor/boringssl/build
./scripts/build-boringssl.sh
```

### Update Submodules

```bash
git submodule update --remote
./scripts/build-boringssl.sh  # Rebuild if BoringSSL updated
zig build
```

## Platform-Specific Notes

### macOS

- Requires Xcode Command Line Tools
- Homebrew recommended for installing dependencies
- Uses kqueue for event loop

### Linux

- Requires build-essential package
- Uses epoll for event loop
- May need to install OpenSSL development headers (even though we use BoringSSL, some system dependencies may require it)

### Windows

- Not yet fully supported (work in progress)
- Will require IOCP backend for uSockets

## CI/CD Integration

For automated builds, ensure your CI environment has:

1. Zig installed
2. CMake installed
3. Go installed
4. C/C++ compiler available
5. Git configured to clone submodules

Example GitHub Actions workflow:

```yaml
- name: Install dependencies
  run: |
    # Install Zig, CMake, Go
    
- name: Checkout with submodules
  uses: actions/checkout@v3
  with:
    submodules: recursive
    
- name: Build BoringSSL
  run: ./scripts/build-boringssl.sh
  
- name: Build ZyncBase
  run: zig build
  
- name: Run tests
  run: zig build test
```
