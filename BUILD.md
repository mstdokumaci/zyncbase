# Building ZyncBase

> [!NOTE]
> ZyncBase is licensed under the [Business Source License 1.1](LICENSE). Source code is available, but production use as a managed service is restricted until 2032-01-01.

## Prerequisites

### Required Tools

1. **Zig** (0.15.2 or later)
   - Download from https://ziglang.org/download/

2. **OpenSSL**
   - macOS: `brew install openssl`
   - Linux: `sudo apt-get install libssl-dev`

3. **C/C++ Compiler**
   - macOS: Xcode Command Line Tools (`xcode-select --install`)
   - Linux: GCC or Clang (`sudo apt-get install build-essential`)

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

### 2. uWebSockets

uWebSockets and µSockets are directly vendored under `vendor/uwebsockets/` and `vendor/usockets/`.

For detailed technical information about the stubs, see the comments in `src/uws_stubs.c`.

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

### Submodule Not Initialized

```
Error: vendor/uwebsockets/App.h not found
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

### Update Submodules

```bash
git submodule update --remote
zig build
```

## Platform-Specific Notes

### macOS

- Requires Xcode Command Line Tools
- Homebrew recommended for installing dependencies (`brew install zig openssl`)
- Uses kqueue for event loop

### Linux

- Requires build-essential package
- Uses epoll for event loop
- `sudo apt-get install libssl-dev` for OpenSSL headers

## CI/CD Integration

For automated builds, ensure your CI environment has:

1. Zig installed
2. OpenSSL headers installed
3. C/C++ compiler available
4. Git configured to clone submodules

Example GitHub Actions workflow:

```yaml
- name: Install dependencies
  run: |
    brew install openssl  # macOS
    # OR: sudo apt-get install -y libssl-dev  # Linux

- name: Checkout with submodules
  uses: actions/checkout@v3
  with:
    submodules: recursive

- name: Build ZyncBase
  run: zig build

- name: Run tests
  run: zig build test
```
