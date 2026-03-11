# MessagePack Parser Implementation

## Overview

The MessagePack parser is a secure, DoS-resistant parser that enforces configurable limits to prevent malicious payloads from exhausting server resources. It uses iterative parsing (not recursive) to prevent stack overflow attacks.

## Features

### Security Limits

All limits are configurable via `MessagePackParser.Config`:

- **Max Depth**: 32 levels (prevents depth bombs)
- **Max Size**: 10 MB (prevents memory exhaustion)
- **Max String Length**: 1 MB (prevents string bombs)
- **Max Array Length**: 100,000 elements (prevents array bombs)
- **Max Map Size**: 100,000 entries (prevents map bombs)

### Iterative Parsing

The parser uses an iterative algorithm with explicit depth tracking instead of recursion. This prevents stack overflow even with deeply nested malicious payloads.

### Connection Violation Tracking

The `ConnectionViolationTracker` tracks repeated limit violations per connection and enables automatic connection closure after a configurable threshold (default: 3 violations).

## Usage

### Basic Parsing

```zig
const allocator = std.heap.page_allocator;

// Initialize parser with default limits
const parser = try MessagePackParser.init(allocator, .{});
defer parser.deinit();

// Parse MessagePack data
const value = try parser.parse(data);
defer parser.freeValue(value);

// Access parsed value
switch (value) {
    .string => |s| std.debug.print("String: {s}\n", .{s}),
    .integer => |i| std.debug.print("Integer: {}\n", .{i}),
    .array => |arr| std.debug.print("Array length: {}\n", .{arr.len}),
    else => {},
}
```

### Custom Limits

```zig
const parser = try MessagePackParser.init(allocator, .{
    .max_depth = 16,
    .max_size = 5 * 1024 * 1024, // 5 MB
    .max_string_length = 512 * 1024, // 512 KB
    .max_array_length = 50_000,
    .max_map_size = 50_000,
    .violation_threshold = 5,
});
```

### Connection Violation Tracking

```zig
var tracker = MessagePackParser.ConnectionViolationTracker.init(allocator, 3);
defer tracker.deinit();

const conn_id: u64 = 12345;

// Record violation
const should_close = try tracker.recordViolation(conn_id);
if (should_close) {
    // Close the connection
    try connection.close(4000, "Repeated parsing limit violations");
}

// Clear violations on successful parse
tracker.clearViolations(conn_id);
```

## Error Handling

The parser returns specific errors for each limit violation:

- `error.MaxDepthExceeded` - Nesting depth exceeds limit
- `error.MaxSizeExceeded` - Total message size exceeds limit
- `error.MaxStringLengthExceeded` - String length exceeds limit
- `error.MaxArrayLengthExceeded` - Array length exceeds limit
- `error.MaxMapSizeExceeded` - Map size exceeds limit
- `error.InvalidFormat` - Invalid MessagePack format byte
- `error.UnexpectedEOF` - Incomplete message data

## Testing

### Unit Tests

Run unit tests with:
```bash
zig test src/messagepack_parser_test.zig
```

Tests cover:
- Basic value parsing (nil, boolean, integers, floats)
- String and binary parsing
- Array and map parsing
- Limit enforcement for all types
- Nested structures
- Connection violation tracking
- Property-based fuzz testing

### Fuzz Tests

Run fuzz tests with:
```bash
zig test src/messagepack_parser_fuzz.zig
```

Fuzz tests include:
- Depth bombs (deeply nested structures)
- Size bombs (huge array declarations)
- String bombs (extremely long strings)
- Map bombs (huge map declarations)
- Random malicious payloads
- Mixed attack vectors
- Incomplete payloads
- Edge case values
- Stress testing with 10,000 random payloads

## Performance

The parser is designed for:
- **Parse throughput**: > 1 GB/sec
- **Parse latency**: < 1 microsecond per KB
- **Memory overhead**: O(depth) not O(size)
- **Bounded parse time**: All inputs complete in < 100ms

## Requirements Validated

This implementation validates the following requirements:

- **3.1**: Max nesting depth of 32 levels
- **3.2**: Max message size of 10 MB
- **3.3**: Max string length of 1 MB
- **3.4**: Max array length of 100,000 elements
- **3.5**: Max map size of 100,000 entries
- **3.6**: Returns MaxDepthExceeded error when depth limit exceeded
- **3.7**: Returns MaxSizeExceeded error when size limit exceeded
- **3.8**: Returns MaxStringLengthExceeded error when string limit exceeded
- **3.9**: Returns MaxArrayLengthExceeded error when array limit exceeded
- **3.10**: Returns MaxMapSizeExceeded error when map limit exceeded
- **3.11**: Uses iterative parsing to prevent stack overflow
- **3.12**: Supports connection closure on repeated violations

## Security Considerations

### DoS Prevention

The parser prevents several DoS attack vectors:

1. **Depth Bombs**: Deeply nested structures that cause stack overflow
2. **Size Bombs**: Huge message declarations that exhaust memory
3. **String Bombs**: Extremely long strings that exhaust memory
4. **Array/Map Bombs**: Huge collections that exhaust memory
5. **Slowloris**: Incomplete messages that tie up resources

### Memory Safety

- Uses `errdefer` to properly clean up on parse errors
- Tracks initialized elements to avoid freeing uninitialized memory
- All allocations have corresponding deallocations
- Tested with AddressSanitizer to detect memory issues

### Connection Management

The violation tracker enables automatic connection closure for clients that repeatedly send malicious payloads, preventing resource exhaustion from persistent attackers.

## Future Enhancements

Potential improvements:

1. **Zero-copy parsing**: Use slices into original buffer where possible
2. **Streaming parser**: Support parsing from streams instead of complete buffers
3. **Schema validation**: Validate parsed values against expected schema
4. **Custom allocators**: Support arena allocators for per-request parsing
5. **Metrics**: Export parsing metrics (parse time, violations, etc.)
