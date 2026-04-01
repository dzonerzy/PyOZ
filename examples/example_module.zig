//! Example PyOZ Module
//!
//! This demonstrates how to create a Python extension module using PyOZ.
//! Notice how you just write normal Zig functions - PyOZ handles all the
//! Python integration automatically!
//!
//! Build: zig build example
//! Test:  cd zig-out/lib && python3 -c "import example; print(example.add(2, 3))"

const std = @import("std");
const pyoz = @import("PyOZ");

// ============================================================================
// Just write normal Zig functions!
// PyOZ automatically converts Python arguments to Zig types,
// calls your function, and converts the result back to Python.
// ============================================================================

/// Add two integers
fn add(a: i64, b: i64) i64 {
    return a + b;
}

/// Multiply two floats
fn multiply(a: f64, b: f64) f64 {
    return a * b;
}

/// Divide two numbers (demonstrates error handling)
fn divide(a: f64, b: f64) !f64 {
    if (b == 0.0) {
        return error.DivisionByZero;
    }
    return a / b;
}

/// Validate input (demonstrates custom exception)
fn validate_positive(n: i64) ?i64 {
    if (n < 0) {
        // Raise our custom ValidationError
        Example.getException(0).raise("Value must be non-negative");
        return null;
    }
    return n;
}

/// Validate positive with Signature override - stubs should show `int` not `int | None`
fn validate_positive_sig(n: i64) pyoz.Signature(?i64, "int") {
    if (n < 0) {
        Example.getException(0).raise("Value must be non-negative");
        return .{ .value = null };
    }
    return .{ .value = n };
}

/// Safe divide using custom exception
fn safe_divide(a: f64, b: f64) ?f64 {
    if (b == 0.0) {
        Example.getException(1).raise("Cannot divide by zero");
        return null;
    }
    return a / b;
}

/// Function with keyword arguments using Args(T)
/// In Python: greet_person(name, greeting="Hello", times=1)
/// Returns a greeting message.
fn greet_person(args: pyoz.Args(struct { name: []const u8, greeting: []const u8 = "Hello", times: i64 = 1 })) struct { []const u8, []const u8, i64 } {
    return .{ args.value.greeting, args.value.name, args.value.times };
}

/// Another keyword function - calculate with defaults
/// power(base, exponent=2.0)
fn power(args: pyoz.Args(struct { base: f64, exponent: f64 = 2.0 })) f64 {
    return std.math.pow(f64, args.value.base, args.value.exponent);
}

/// CPU-intensive computation that releases the GIL
/// This allows other Python threads to run while computing
fn compute_sum_no_gil(n: i64) i64 {
    // Release the GIL - other Python threads can now run!
    const gil = pyoz.releaseGIL();
    defer gil.acquire();

    // Do expensive computation without the GIL
    // Use wrapping arithmetic to avoid overflow in debug builds
    var sum: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        // Simulate some work with wrapping to avoid overflow
        sum +%= @mod(i *% i, 1000000007);
    }
    return sum;
}

/// Same computation but keeps the GIL (for comparison)
fn compute_sum_with_gil(n: i64) i64 {
    var sum: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        sum +%= @mod(i *% i, 1000000007);
    }
    return sum;
}

/// Interruptible sum — supports Ctrl+C during long computation
fn interruptible_sum(n: i64) !i64 {
    var sum: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        if (@mod(i, 100000) == 0) try pyoz.checkSignals();
        sum +%= i;
    }
    return sum;
}

// ============================================================================
// Dict support examples
// ============================================================================

/// Accept a Python dict and sum its integer values
fn sum_dict_values(dict: pyoz.DictView([]const u8, i64)) i64 {
    var sum: i64 = 0;
    var iter = dict.iterator();
    while (iter.next()) |entry| {
        sum += entry.value;
    }
    return sum;
}

/// Get a value from a dict by key
fn get_dict_value(dict: pyoz.DictView([]const u8, i64), key: []const u8) ?i64 {
    return dict.get(key);
}

/// Return a dict (using Dict type)
fn make_dict() pyoz.Dict([]const u8, i64) {
    const entries = &[_]pyoz.Dict([]const u8, i64).Entry{
        .{ .key = "one", .value = 1 },
        .{ .key = "two", .value = 2 },
        .{ .key = "three", .value = 3 },
    };
    return .{ .entries = entries };
}

/// Count items in a dict
fn dict_len(dict: pyoz.DictView([]const u8, i64)) i64 {
    return @intCast(dict.len());
}

/// Check if key exists in dict
fn dict_has_key(dict: pyoz.DictView([]const u8, i64), key: []const u8) bool {
    return dict.contains(key);
}

// ============================================================================
// List input examples (ListView for zero-copy access)
// ============================================================================

/// Sum all integers in a list using zero-copy ListView
fn sum_list(items: pyoz.ListView(i64)) i64 {
    var total: i64 = 0;
    var iter = items.iterator();
    while (iter.next()) |value| {
        total += value;
    }
    return total;
}

/// Get element at index from a list
fn list_get(items: pyoz.ListView(i64), index: i64) ?i64 {
    if (index < 0) return null;
    return items.get(@intCast(index));
}

/// Get list length
fn list_len(items: pyoz.ListView(i64)) i64 {
    return @intCast(items.len());
}

/// Calculate average of floats in a list
fn list_average(items: pyoz.ListView(f64)) ?f64 {
    const len = items.len();
    if (len == 0) return null;

    var total: f64 = 0.0;
    var iter = items.iterator();
    while (iter.next()) |value| {
        total += value;
    }
    return total / @as(f64, @floatFromInt(len));
}

/// Find max value in a list
fn list_max(items: pyoz.ListView(i64)) ?i64 {
    if (items.isEmpty()) return null;

    var max_val: ?i64 = null;
    var iter = items.iterator();
    while (iter.next()) |value| {
        if (max_val == null or value > max_val.?) {
            max_val = value;
        }
    }
    return max_val;
}

/// Check if list contains a value
fn list_contains(items: pyoz.ListView(i64), target: i64) bool {
    var iter = items.iterator();
    while (iter.next()) |value| {
        if (value == target) return true;
    }
    return false;
}

/// Process list of strings - join with separator
fn join_strings(items: pyoz.ListView([]const u8), sep: []const u8) ?[]const u8 {
    const len = items.len();
    if (len == 0) return "";

    // For simplicity, use a fixed buffer
    var buffer: [4096]u8 = undefined;
    var pos: usize = 0;

    for (0..len) |i| {
        if (items.get(i)) |s| {
            if (i > 0) {
                if (pos + sep.len > buffer.len) return null;
                @memcpy(buffer[pos..][0..sep.len], sep);
                pos += sep.len;
            }
            if (pos + s.len > buffer.len) return null;
            @memcpy(buffer[pos..][0..s.len], s);
            pos += s.len;
        }
    }
    // Return slice (Python will copy it)
    return buffer[0..pos];
}

// ============================================================================
// Set examples (SetView for input, Set/FrozenSet for output)
// ============================================================================

/// Sum all integers in a set using SetView
fn sum_set(items: pyoz.SetView(i64)) i64 {
    var total: i64 = 0;
    var iter = items.iterator();
    defer iter.deinit();
    while (iter.next()) |value| {
        total += value;
    }
    return total;
}

/// Get set length
fn set_len(items: pyoz.SetView(i64)) i64 {
    return @intCast(items.len());
}

/// Check if set contains a value
fn set_has(items: pyoz.SetView(i64), value: i64) bool {
    return items.contains(value);
}

/// Return a set of integers
fn make_set() pyoz.Set(i64) {
    const items = &[_]i64{ 1, 2, 3, 4, 5 };
    return .{ .items = items };
}

/// Return a frozen set of strings
fn make_frozenset() pyoz.FrozenSet([]const u8) {
    const items = &[_][]const u8{ "apple", "banana", "cherry" };
    return .{ .items = items };
}

// ============================================================================
// Iterator examples - IteratorView can accept ANY iterable
// ============================================================================

/// Sum all integers from any iterable (list, tuple, set, generator, etc.)
fn iter_sum(items: pyoz.IteratorView(i64)) i64 {
    var iter = items;
    var total: i64 = 0;
    while (iter.next()) |value| {
        total += value;
    }
    return total;
}

/// Count items in any iterable
fn iter_count(items: pyoz.IteratorView(i64)) i64 {
    var iter = items;
    return @intCast(iter.count());
}

/// Find the maximum value in any iterable of integers
fn iter_max(items: pyoz.IteratorView(i64)) ?i64 {
    var iter = items;
    var max_val: ?i64 = null;
    while (iter.next()) |value| {
        if (max_val == null or value > max_val.?) {
            max_val = value;
        }
    }
    return max_val;
}

/// Find the minimum value in any iterable of integers
fn iter_min(items: pyoz.IteratorView(i64)) ?i64 {
    var iter = items;
    var min_val: ?i64 = null;
    while (iter.next()) |value| {
        if (min_val == null or value < min_val.?) {
            min_val = value;
        }
    }
    return min_val;
}

/// Calculate the product of all integers in an iterable
fn iter_product(items: pyoz.IteratorView(i64)) i64 {
    var iter = items;
    var product: i64 = 1;
    while (iter.next()) |value| {
        product *= value;
    }
    return product;
}

/// Join strings from any iterable with a separator
fn iter_join(items: pyoz.IteratorView([]const u8), sep: []const u8) []const u8 {
    var iter = items;
    // For simplicity, we'll just concatenate the first few items
    // In a real implementation, you'd use an allocator
    var result: [1024]u8 = undefined;
    var pos: usize = 0;
    var first = true;

    while (iter.next()) |s| {
        if (!first and pos + sep.len < result.len) {
            @memcpy(result[pos .. pos + sep.len], sep);
            pos += sep.len;
        }
        first = false;

        const copy_len = @min(s.len, result.len - pos);
        if (copy_len > 0) {
            @memcpy(result[pos .. pos + copy_len], s[0..copy_len]);
            pos += copy_len;
        }
    }

    // Return static buffer (valid for the duration of the Python call)
    const static = struct {
        var buf: [1024]u8 = undefined;
    };
    @memcpy(static.buf[0..pos], result[0..pos]);
    return static.buf[0..pos];
}

/// Calculate average of floats from any iterable
fn iter_average(items: pyoz.IteratorView(f64)) ?f64 {
    var iter = items;
    var sum: f64 = 0;
    var count: usize = 0;
    while (iter.next()) |value| {
        sum += value;
        count += 1;
    }
    if (count == 0) return null;
    return sum / @as(f64, @floatFromInt(count));
}

// ============================================================================
// Iterator producer examples - Return iterators to Python
// ============================================================================

/// Return a fixed list of numbers using Iterator (eager, becomes a Python list)
fn get_fibonacci() pyoz.Iterator(i64) {
    const fibs = [_]i64{ 1, 1, 2, 3, 5, 8, 13, 21, 34, 55 };
    return .{ .items = &fibs };
}

/// Return squares of 1-5 using Iterator
fn get_squares() pyoz.Iterator(i64) {
    const squares = [_]i64{ 1, 4, 9, 16, 25 };
    return .{ .items = &squares };
}

/// State for the range lazy iterator
const RangeState = struct {
    current: i64,
    end: i64,
    step: i64,

    pub fn next(self: *@This()) ?i64 {
        if ((self.step > 0 and self.current >= self.end) or
            (self.step < 0 and self.current <= self.end))
        {
            return null;
        }
        const val = self.current;
        self.current += self.step;
        return val;
    }
};

/// Return a lazy range iterator (like Python's range())
fn lazy_range(start: i64, end: i64, step: i64) pyoz.LazyIterator(i64, RangeState) {
    return .{ .state = .{ .current = start, .end = end, .step = step } };
}

/// State for counting iterator
const CountState = struct {
    current: i64,
    limit: i64,

    pub fn next(self: *@This()) ?i64 {
        if (self.current >= self.limit) return null;
        const val = self.current;
        self.current += 1;
        return val;
    }
};

/// Return a lazy counter that counts from 0 to n-1
fn lazy_count(n: i64) pyoz.LazyIterator(i64, CountState) {
    return .{ .state = .{ .current = 0, .limit = n } };
}

/// State for fibonacci generator
const FibState = struct {
    a: i64,
    b: i64,
    remaining: i64,

    pub fn next(self: *@This()) ?i64 {
        if (self.remaining <= 0) return null;
        const val = self.a;
        const new_b = self.a + self.b;
        self.a = self.b;
        self.b = new_b;
        self.remaining -= 1;
        return val;
    }
};

/// Return a lazy fibonacci generator that yields n fibonacci numbers
fn lazy_fibonacci(n: i64) pyoz.LazyIterator(i64, FibState) {
    return .{ .state = .{ .a = 0, .b = 1, .remaining = n } };
}

// ============================================================================
// DateTime examples
// ============================================================================

/// Accept a datetime and return its components as a tuple
fn datetime_parts(dt: pyoz.DateTime) struct { i32, u8, u8, u8, u8, u8, u32 } {
    return .{ dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, dt.microsecond };
}

/// Accept a date and return its components
fn date_parts(d: pyoz.Date) struct { i32, u8, u8 } {
    return .{ d.year, d.month, d.day };
}

/// Accept a time and return its components
fn time_parts(t: pyoz.Time) struct { u8, u8, u8, u32 } {
    return .{ t.hour, t.minute, t.second, t.microsecond };
}

/// Accept a timedelta and return its components
fn timedelta_parts(td: pyoz.TimeDelta) struct { i32, i32, i32 } {
    return .{ td.days, td.seconds, td.microseconds };
}

/// Create and return a datetime
fn make_datetime() pyoz.DateTime {
    return pyoz.DateTime.initWithMicrosecond(2024, 12, 25, 10, 30, 45, 123456);
}

/// Create and return a date
fn make_date() pyoz.Date {
    return pyoz.Date.init(2024, 7, 4);
}

/// Create and return a time
fn make_time() pyoz.Time {
    return pyoz.Time.initWithMicrosecond(14, 30, 0, 500000);
}

/// Create and return a timedelta
fn make_timedelta() pyoz.TimeDelta {
    return pyoz.TimeDelta.init(5, 3600, 123456);
}

/// Add days to a date
fn add_days_to_date(d: pyoz.Date, days: i32) pyoz.Date {
    // Simple implementation - doesn't handle month/year overflow properly
    // Just for demonstration
    return pyoz.Date.init(d.year, d.month, @intCast(@as(i32, d.day) + days));
}

// ============================================================================
// Bytes examples
// ============================================================================

/// Get the length of bytes
fn bytes_len(b: pyoz.Bytes) i64 {
    return @intCast(b.data.len);
}

/// Sum all bytes
fn bytes_sum(b: pyoz.Bytes) i64 {
    var sum: i64 = 0;
    for (b.data) |byte| {
        sum += byte;
    }
    return sum;
}

/// Create bytes from a pattern
fn make_bytes() pyoz.Bytes {
    const data = &[_]u8{ 0x48, 0x65, 0x6c, 0x6c, 0x6f }; // "Hello"
    return .{ .data = data };
}

/// Check if bytes starts with a byte value
fn bytes_starts_with(b: pyoz.Bytes, value: u8) bool {
    if (b.data.len == 0) return false;
    return b.data[0] == value;
}

// ============================================================================
// Path examples
// ============================================================================

/// Get the path string from a Path object
fn path_str(p: pyoz.Path) []const u8 {
    return p.path;
}

/// Get the length of a path
fn path_len(p: pyoz.Path) i64 {
    return @intCast(p.path.len);
}

/// Create and return a path
fn make_path() pyoz.Path {
    return pyoz.Path.init("/home/user/documents");
}

/// Check if path starts with a prefix
fn path_starts_with(p: pyoz.Path, prefix: []const u8) bool {
    if (p.path.len < prefix.len) return false;
    return std.mem.eql(u8, p.path[0..prefix.len], prefix);
}

// ============================================================================
// Decimal examples
// ============================================================================

/// Accept a decimal and return its string representation
fn decimal_str(d: pyoz.Decimal) []const u8 {
    return d.value;
}

/// Create and return a decimal
fn make_decimal() pyoz.Decimal {
    return pyoz.Decimal.init("123.456789");
}

/// Double a decimal value (demonstration - returns as string then creates new)
fn decimal_double(d: pyoz.Decimal) pyoz.Decimal {
    // Parse and double (simple demonstration)
    if (d.toFloat()) |f| {
        var buf: [64]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, "{d}", .{f * 2.0}) catch return d;
        return pyoz.Decimal.init(result);
    }
    return d;
}

// ============================================================================
// BigInt (i128/u128) examples
// ============================================================================

/// Accept an i128 and return it
fn bigint_echo(n: i128) i128 {
    return n;
}

/// Accept a u128 and return it
fn biguint_echo(n: u128) u128 {
    return n;
}

/// Return a large i128 constant
fn bigint_max() i128 {
    return 170141183460469231731687303715884105727; // i128 max
}

/// Return a large u128 constant
fn biguint_large() u128 {
    return 340282366920938463463374607431768211455; // u128 max
}

/// Add two i128 values
fn bigint_add(a: i128, b: i128) i128 {
    return a + b;
}

// ============================================================================
// Complex number examples
// ============================================================================

/// Accept a complex number and return it
fn complex_echo(c: pyoz.Complex) pyoz.Complex {
    return c;
}

/// Create a complex number
fn make_complex(real: f64, imag: f64) pyoz.Complex {
    return pyoz.Complex.init(real, imag);
}

/// Get the magnitude of a complex number
fn complex_magnitude(c: pyoz.Complex) f64 {
    return @sqrt(c.real * c.real + c.imag * c.imag);
}

/// Add two complex numbers
fn complex_add(a: pyoz.Complex, b: pyoz.Complex) pyoz.Complex {
    return pyoz.Complex.init(a.real + b.real, a.imag + b.imag);
}

/// Multiply two complex numbers
fn complex_mul(a: pyoz.Complex, b: pyoz.Complex) pyoz.Complex {
    // (a + bi)(c + di) = (ac - bd) + (ad + bc)i
    return pyoz.Complex.init(
        a.real * b.real - a.imag * b.imag,
        a.real * b.imag + a.imag * b.real,
    );
}

// ============================================================================
// Exception catching examples
// ============================================================================

// ============================================================================
// Callable wrapper examples
// ============================================================================

/// Apply a Python callback to two arguments and return the result
fn apply_callback(callback: pyoz.Callable(i64), x: i64, y: i64) ?i64 {
    return callback.call(.{ x, y });
}

/// Apply a transform callback to a single value
fn transform_value(callback: pyoz.Callable(f64), value: f64) ?f64 {
    return callback.call(.{value});
}

/// Call a callback with no arguments
fn call_no_args(callback: pyoz.Callable(i64)) ?i64 {
    return callback.callNoArgs();
}

/// Call a void callback (e.g., for side effects)
fn call_void(callback: pyoz.Callable(void), x: i64) bool {
    return callback.call(.{x});
}

/// Call a Python callable and catch any exception
/// Returns the result or -1 if an exception occurred
fn call_and_catch(callable: *pyoz.PyObject, arg: i64) i64 {
    // Convert arg to Python
    const py_arg = pyoz.Conversions.toPy(i64, arg) orelse return -1;
    defer pyoz.py.Py_DecRef(py_arg);

    // Build args tuple
    const args_tuple = pyoz.py.PyTuple_Pack(.{py_arg}) orelse return -1;
    defer pyoz.py.Py_DecRef(args_tuple);

    // Call the callable
    const result = pyoz.py.PyObject_CallObject(callable, args_tuple);

    if (result) |r| {
        defer pyoz.py.Py_DecRef(r);
        return pyoz.Conversions.fromPy(i64, r) catch -1;
    } else {
        // Exception occurred - catch it!
        if (pyoz.catchException()) |*exc| {
            defer @constCast(exc).deinit();

            // Check what type of exception it is
            if (exc.isValueError()) {
                // Handle ValueError - return -100
                return -100;
            } else if (exc.isTypeError()) {
                // Handle TypeError - return -200
                return -200;
            } else if (exc.isZeroDivisionError()) {
                // Handle ZeroDivisionError - return -300
                return -300;
            } else {
                // Unknown exception - re-raise it
                exc.reraise();
                return -1;
            }
        }
        return -1;
    }
}

/// Demonstrate raising exceptions from Zig
fn raise_value_error(msg: []const u8) ?i64 {
    // For runtime messages, use PyErr_SetString directly
    var buf: [256]u8 = undefined;
    const len = @min(msg.len, 255);
    @memcpy(buf[0..len], msg[0..len]);
    buf[len] = 0;
    pyoz.py.PyErr_SetString(pyoz.py.PyExc_ValueError(), @ptrCast(&buf));
    return null;
}

/// Test exception checking - returns exception type name or "none"
fn check_exception_type(callable: *pyoz.PyObject) []const u8 {
    // Call with no args to trigger potential exception
    const result = pyoz.py.PyObject_CallObject(callable, null);

    if (result) |r| {
        pyoz.py.Py_DecRef(r);
        return "none";
    } else {
        if (pyoz.catchException()) |*exc| {
            defer @constCast(exc).deinit();

            if (exc.isValueError()) return "ValueError";
            if (exc.isTypeError()) return "TypeError";
            if (exc.isKeyError()) return "KeyError";
            if (exc.isIndexError()) return "IndexError";
            if (exc.isRuntimeError()) return "RuntimeError";
            if (exc.isStopIteration()) return "StopIteration";
            return "other";
        }
        return "unknown";
    }
}

// ============================================================================
// Error mapping examples
// ============================================================================

/// Function that can return different error types
fn parse_and_validate(value: i64) !i64 {
    if (value < 0) {
        return error.NegativeValue;
    }
    if (value > 1000) {
        return error.ValueTooLarge;
    }
    if (value == 42) {
        return error.ForbiddenValue;
    }
    return value * 2;
}

/// Another function with mapped errors
fn lookup_index(index: i64) !i64 {
    const data = [_]i64{ 10, 20, 30, 40, 50 };
    if (index < 0 or index >= data.len) {
        return error.IndexOutOfBounds;
    }
    return data[@intCast(index)];
}

// ============================================================================
// Named keyword arguments example
// ============================================================================

/// Named arguments for greet_named function
const GreetNamedArgs = struct {
    name: []const u8, // Required
    greeting: []const u8 = "Hello", // Optional with default
    times: i64 = 1, // Optional with default
    excited: bool = false, // Optional with default
};

/// Greet using named keyword arguments
fn greet_named(args: pyoz.Args(GreetNamedArgs)) struct { []const u8, []const u8, i64, bool } {
    const a = args.value;
    return .{ a.greeting, a.name, a.times, a.excited };
}

/// Named arguments for calculate function
const CalcArgs = struct {
    x: f64, // Required
    y: f64, // Required
    operation: []const u8 = "add", // Optional with default
};

/// Calculate using named keyword arguments
fn calculate_named(args: pyoz.Args(CalcArgs)) f64 {
    const a = args.value;
    const op = a.operation;

    if (std.mem.eql(u8, op, "add")) {
        return a.x + a.y;
    } else if (std.mem.eql(u8, op, "sub")) {
        return a.x - a.y;
    } else if (std.mem.eql(u8, op, "mul")) {
        return a.x * a.y;
    } else if (std.mem.eql(u8, op, "div")) {
        return a.x / a.y;
    }
    return 0.0;
}

/// Greet someone by name
fn greet(name: []const u8) []const u8 {
    // In a real implementation you'd want to allocate
    // For now just return a static greeting
    _ = name;
    return "Hello from Zig!";
}

/// Check if a number is even
fn is_even(n: i64) bool {
    return @mod(n, 2) == 0;
}

/// Get the answer to everything
fn answer() i64 {
    return 42;
}

/// Calculate distance between two points (demonstrates passing class instances!)
fn distance(p1: *const Point, p2: *const Point) f64 {
    const dx = p1.x - p2.x;
    const dy = p1.y - p2.y;
    return @sqrt(dx * dx + dy * dy);
}

/// Calculate midpoint between two points (returns tuple!)
fn midpoint_coords(p1: *const Point, p2: *const Point) struct { f64, f64 } {
    return .{
        (p1.x + p2.x) / 2.0,
        (p1.y + p2.y) / 2.0,
    };
}

/// Return a list of integers (demonstrates list return)
fn get_range(n: i64) []const i64 {
    // Note: In real use you'd want to allocate, but for demo we use comptime
    const items = &[_]i64{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const len: usize = @intCast(@min(n, 10));
    return items[0..len];
}

/// Return a list of floats
fn get_fibonacci_ratios() []const f64 {
    const ratios = &[_]f64{ 1.0, 1.0, 2.0, 1.5, 1.666, 1.6, 1.625, 1.615 };
    return ratios;
}

/// Sum a fixed-size array of 3 integers (demonstrates list input)
fn sum_triple(arr: [3]i64) i64 {
    return arr[0] + arr[1] + arr[2];
}

/// Compute dot product of two 3D vectors
fn dot_product_3d(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

// ============================================================================
// Class Example - A 2D Point
// PyOZ automatically:
// - Generates __init__ that accepts (x, y)
// - Creates getters/setters for x and y fields
// - Wraps pub fn methods as Python methods
// ============================================================================

// ============================================================================
// BoundedValue - demonstrates custom getters/setters
// The value is clamped to [0, 100] and transformed on get/set
// ============================================================================

const BoundedValue = struct {
    value: f64,
    access_count: i64,

    /// Custom getter for 'value' - tracks access and returns value
    pub fn get_value(self: *const BoundedValue) f64 {
        // Note: in a real use case we might want mutable self for tracking
        return self.value;
    }

    /// Custom setter for 'value' - clamps to [0, 100]
    pub fn set_value(self: *BoundedValue, new_val: f64) void {
        self.value = @max(0.0, @min(100.0, new_val));
        self.access_count += 1;
    }

    /// Get access count (regular method)
    pub fn get_access_count(self: *const BoundedValue) i64 {
        return self.access_count;
    }
};

// ============================================================================
// VulnArray - test class with usize index to verify PyOZ negative index fix
// ============================================================================

const VulnArray = struct {
    data: [8]i64 = [_]i64{ 10, 20, 30, 40, 50, 60, 70, 80 },

    pub fn new() VulnArray {
        return VulnArray{};
    }

    pub fn __len__(self: *const VulnArray) usize {
        _ = self;
        return 8;
    }

    // Uses usize - PyOZ should wrap negative indices automatically
    pub fn __getitem__(self: *const VulnArray, index: usize) i64 {
        return self.data[index];
    }
};

// ============================================================================
// BadBuffer - test class that exports a buffer with negative shape (for security testing)
// This tests that PyOZ validates buffer shape values before using them
// ============================================================================

const BadBuffer = struct {
    data: [8]i64 = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8 },

    pub fn new() BadBuffer {
        return BadBuffer{};
    }

    // Deliberately malformed buffer shape - negative value
    var bad_shape: [1]pyoz.Py_ssize_t = .{-1};
    var buffer_format: [2:0]u8 = .{ 'q', 0 }; // 'q' = signed long long (i64)

    /// __buffer__ - exports buffer with NEGATIVE shape (bug test)
    pub fn __buffer__(self: *BadBuffer) pyoz.BufferInfo {
        return .{
            .ptr = @ptrCast(&self.data),
            .len = 8 * @sizeOf(i64),
            .readonly = true,
            .format = &buffer_format,
            .itemsize = @sizeOf(i64),
            .ndim = 1,
            .shape = &bad_shape, // NEGATIVE! Should cause PyOZ to reject
            .strides = null,
        };
    }
};

// ============================================================================
// BadStrideBuffer - test class that exports a buffer with negative strides (for security testing)
// ============================================================================

const BadStrideBuffer = struct {
    data: [4]i64 = [_]i64{ 1, 2, 3, 4 },

    pub fn new() BadStrideBuffer {
        return BadStrideBuffer{};
    }

    // Valid shape but NEGATIVE stride
    var shape_2d: [2]pyoz.Py_ssize_t = .{ 2, 2 }; // 2x2 array
    var bad_strides: [2]pyoz.Py_ssize_t = .{ -16, 8 }; // NEGATIVE row stride!
    var buffer_format: [2:0]u8 = .{ 'q', 0 }; // 'q' = signed long long (i64)

    /// __buffer__ - exports buffer with NEGATIVE strides (bug test)
    pub fn __buffer__(self: *BadStrideBuffer) pyoz.BufferInfo {
        return .{
            .ptr = @ptrCast(&self.data),
            .len = 4 * @sizeOf(i64),
            .readonly = true,
            .format = &buffer_format,
            .itemsize = @sizeOf(i64),
            .ndim = 2,
            .shape = &shape_2d,
            .strides = &bad_strides, // NEGATIVE! Should cause panic in get2D
        };
    }
};

// ============================================================================
// IntArray - demonstrates sequence protocol (__len__, __getitem__, __contains__, __iter__)
// ============================================================================

const IntArray = struct {
    data: [8]i64,
    len: usize,
    iter_index: usize, // For iteration

    /// __len__ - return length
    pub fn __len__(self: *const IntArray) usize {
        return self.len;
    }

    /// __getitem__ - get item by index
    pub fn __getitem__(self: *const IntArray, index: i64) !i64 {
        const len_i64: i64 = @intCast(self.len);
        const wrapped = if (index < 0) index + len_i64 else index;

        // Check bounds after wrapping (handles both negative overflow and positive overflow)
        if (wrapped < 0 or wrapped >= len_i64) {
            return error.IndexOutOfBounds;
        }

        return self.data[@intCast(wrapped)];
    }

    /// __setitem__ - set item by index
    pub fn __setitem__(self: *IntArray, index: i64, value: i64) !void {
        const len_i64: i64 = @intCast(self.len);
        const wrapped = if (index < 0) index + len_i64 else index;

        if (wrapped < 0 or wrapped >= len_i64) {
            return error.IndexOutOfBounds;
        }
        self.data[@intCast(wrapped)] = value;
    }

    /// __delitem__ - delete item by index (shifts remaining items)
    pub fn __delitem__(self: *IntArray, index: i64) !void {
        const len_i64: i64 = @intCast(self.len);
        const wrapped = if (index < 0) index + len_i64 else index;

        if (wrapped < 0 or wrapped >= len_i64) {
            return error.IndexOutOfBounds;
        }

        const idx: usize = @intCast(wrapped);

        // Shift remaining elements
        var i: usize = idx;
        while (i < self.len - 1) : (i += 1) {
            self.data[i] = self.data[i + 1];
        }
        self.len -= 1;
    }

    /// __contains__ - check if value is in array
    pub fn __contains__(self: *const IntArray, value: i64) bool {
        for (self.data[0..self.len]) |item| {
            if (item == value) return true;
        }
        return false;
    }

    /// __iter__ - return self as iterator
    pub fn __iter__(self: *IntArray) *IntArray {
        self.iter_index = 0;
        return self;
    }

    /// __next__ - get next item (null signals StopIteration)
    pub fn __next__(self: *IntArray) ?i64 {
        if (self.iter_index >= self.len) {
            return null;
        }
        const value = self.data[self.iter_index];
        self.iter_index += 1;
        return value;
    }

    /// Static method to create from values
    pub fn from_values(a: i64, b: i64, c: i64) IntArray {
        var arr = IntArray{
            .data = [_]i64{0} ** 8,
            .len = 3,
            .iter_index = 0,
        };
        arr.data[0] = a;
        arr.data[1] = b;
        arr.data[2] = c;
        return arr;
    }

    /// Append a value (if space available)
    pub fn append(self: *IntArray, value: i64) !void {
        if (self.len >= 8) {
            return error.ArrayFull;
        }
        self.data[self.len] = value;
        self.len += 1;
    }

    // For buffer protocol - store shape as instance data
    var buffer_shape: [1]pyoz.Py_ssize_t = .{0};
    var buffer_format: [2:0]u8 = .{ 'q', 0 }; // 'q' = signed long long (i64)

    /// __buffer__ - expose data for numpy/memoryview access
    pub fn __buffer__(self: *IntArray) pyoz.BufferInfo {
        // Update shape to current length
        buffer_shape[0] = @intCast(self.len);
        return .{
            .ptr = @ptrCast(&self.data),
            .len = self.len * @sizeOf(i64),
            .readonly = false,
            .format = &buffer_format,
            .itemsize = @sizeOf(i64),
            .ndim = 1,
            .shape = &buffer_shape,
            .strides = null,
        };
    }
};

const Point = struct {
    // Class docstring - accessible via Point.__doc__ in Python
    // Must be [*:0]const u8 (null-terminated) for Python compatibility
    pub const __doc__: [*:0]const u8 = "A 2D point with x and y coordinates.\n\nSupports vector arithmetic (+, -, negation) and geometric operations.";

    // Field docstrings - accessible via help(Point.x) in Python
    pub const x__doc__: [*:0]const u8 = "The x coordinate of the point";
    pub const y__doc__: [*:0]const u8 = "The y coordinate of the point";

    x: f64,
    y: f64,

    // Method docstrings - accessible via help(Point.magnitude) in Python
    pub const magnitude__doc__: [*:0]const u8 = "Calculate the distance from this point to the origin.\n\nReturns:\n    float: The Euclidean distance sqrt(x^2 + y^2)";

    /// Calculate distance from origin
    pub fn magnitude(self: *const Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    // Computed property docstring
    pub const length__doc__: [*:0]const u8 = "The length (magnitude) of the point vector.\n\nThis is a read/write property - setting it scales the point.";

    /// Computed property: length (same as magnitude, demonstrates get_X pattern)
    pub fn get_length(self: *const Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    /// Computed property setter: length (scales point to have given length)
    pub fn set_length(self: *Point, new_length: f64) void {
        const current = @sqrt(self.x * self.x + self.y * self.y);
        if (current > 0.0) {
            const factor = new_length / current;
            self.x *= factor;
            self.y *= factor;
        }
    }

    /// Scale the point by a factor
    pub fn scale(self: *Point, factor: f64) void {
        self.x *= factor;
        self.y *= factor;
    }

    /// Add another point's coordinates to this one (returns new x+y sum for demo)
    pub fn dot(self: *const Point, other_x: f64, other_y: f64) f64 {
        return self.x * other_x + self.y * other_y;
    }

    /// Translate the point by dx and dy (keyword arguments)
    pub fn translate(self: *Point, args: pyoz.Args(struct {
        dx: f64 = 0,
        dy: f64 = 0,
    })) void {
        self.x += args.value.dx;
        self.y += args.value.dy;
    }

    /// Static method: create origin point (no self!)
    pub fn origin() Point {
        return .{ .x = 0.0, .y = 0.0 };
    }

    /// Static method: create unit point from angle
    pub fn from_angle(radians: f64) Point {
        return .{ .x = @cos(radians), .y = @sin(radians) };
    }

    /// Class method: create point from polar coordinates
    /// First param is `type` to indicate this is a classmethod
    pub fn from_polar(comptime cls: type, r: f64, theta: f64) Point {
        _ = cls; // cls is the type itself (Point)
        return .{ .x = r * @cos(theta), .y = r * @sin(theta) };
    }

    // ========== Magic Methods ==========

    /// __repr__ - string representation
    pub fn __repr__(self: *const Point) []const u8 {
        // In real code you'd format this properly, but for demo:
        _ = self;
        return "Point(...)";
    }

    /// __eq__ - equality comparison
    pub fn __eq__(self: *const Point, other: *const Point) bool {
        return self.x == other.x and self.y == other.y;
    }

    /// __add__ - vector addition
    pub fn __add__(self: *const Point, other: *const Point) Point {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    /// __sub__ - vector subtraction
    pub fn __sub__(self: *const Point, other: *const Point) Point {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    /// __neg__ - negation
    pub fn __neg__(self: *const Point) Point {
        return .{ .x = -self.x, .y = -self.y };
    }
};

// ============================================================================
// Number class - demonstrates division and modulo operators
// ============================================================================

/// A simple number wrapper demonstrating __truediv__, __floordiv__, __mod__
const Number = struct {
    value: f64,

    pub fn __new__(value: f64) Number {
        return .{ .value = value };
    }

    pub fn __repr__(self: *const Number) []const u8 {
        _ = self;
        return "Number(...)";
    }

    /// Get the value
    pub fn get_value(self: *const Number) f64 {
        return self.value;
    }

    /// __add__
    pub fn __add__(self: *const Number, other: *const Number) Number {
        return .{ .value = self.value + other.value };
    }

    /// __sub__
    pub fn __sub__(self: *const Number, other: *const Number) Number {
        return .{ .value = self.value - other.value };
    }

    /// __mul__
    pub fn __mul__(self: *const Number, other: *const Number) Number {
        return .{ .value = self.value * other.value };
    }

    /// __truediv__ - true division (always returns float)
    pub fn __truediv__(self: *const Number, other: *const Number) !Number {
        if (other.value == 0.0) {
            return error.DivisionByZero;
        }
        return .{ .value = self.value / other.value };
    }

    /// __floordiv__ - floor division
    pub fn __floordiv__(self: *const Number, other: *const Number) !Number {
        if (other.value == 0.0) {
            return error.DivisionByZero;
        }
        return .{ .value = @floor(self.value / other.value) };
    }

    /// __mod__ - modulo
    pub fn __mod__(self: *const Number, other: *const Number) !Number {
        if (other.value == 0.0) {
            return error.DivisionByZero;
        }
        return .{ .value = @mod(self.value, other.value) };
    }

    /// __divmod__ - returns tuple (quotient, remainder)
    pub fn __divmod__(self: *const Number, other: *const Number) !struct { Number, Number } {
        if (other.value == 0.0) {
            return error.DivisionByZero;
        }
        const quotient = @floor(self.value / other.value);
        const remainder = @mod(self.value, other.value);
        return .{ .{ .value = quotient }, .{ .value = remainder } };
    }

    /// __neg__
    pub fn __neg__(self: *const Number) Number {
        return .{ .value = -self.value };
    }

    /// __eq__
    pub fn __eq__(self: *const Number, other: *const Number) bool {
        return self.value == other.value;
    }
};

// ============================================================================
// Timer class - demonstrates context manager (__enter__/__exit__)
// ============================================================================

/// A simple timer context manager
const Timer = struct {
    name: [64]u8,
    name_len: usize,
    started: bool,
    counter: i64,

    pub fn __new__(name: []const u8) Timer {
        var t = Timer{
            .name = undefined,
            .name_len = @min(name.len, 64),
            .started = false,
            .counter = 0,
        };
        @memcpy(t.name[0..t.name_len], name[0..t.name_len]);
        return t;
    }

    pub fn __repr__(self: *const Timer) []const u8 {
        _ = self;
        return "Timer(...)";
    }

    /// __enter__ - called when entering 'with' block
    /// Returns self (the context manager itself)
    pub fn __enter__(self: *Timer) *Timer {
        self.started = true;
        self.counter = 0;
        return self;
    }

    /// __exit__ - called when exiting 'with' block
    /// In Python: __exit__(self, exc_type, exc_val, exc_tb)
    /// Returns True to suppress exceptions, False to propagate
    /// For simplicity, we just take no args and return false (don't suppress)
    pub fn __exit__(self: *Timer) bool {
        self.started = false;
        return false; // Don't suppress exceptions
    }

    /// Get the timer name
    pub fn get_name(self: *const Timer) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Check if timer is active
    pub fn is_active(self: *const Timer) bool {
        return self.started;
    }

    /// Increment counter (simulating work)
    pub fn tick(self: *Timer) void {
        if (self.started) {
            self.counter += 1;
        }
    }

    /// Get counter value
    pub fn get_count(self: *const Timer) i64 {
        return self.counter;
    }
};

// ============================================================================
// Version class - demonstrates all comparison operators
// ============================================================================

/// A semantic version with major.minor.patch
const Version = struct {
    major: i32,
    minor: i32,
    patch: i32,

    pub fn __new__(major: i32, minor: i32, patch: i32) Version {
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn __repr__(self: *const Version) []const u8 {
        _ = self;
        return "Version(...)";
    }

    pub fn __str__(self: *const Version) []const u8 {
        _ = self;
        return "v...";
    }

    /// __eq__ - versions are equal if all components match
    pub fn __eq__(self: *const Version, other: *const Version) bool {
        return self.major == other.major and self.minor == other.minor and self.patch == other.patch;
    }

    /// __ne__ - explicit not-equal (optional, derived from __eq__ if not provided)
    pub fn __ne__(self: *const Version, other: *const Version) bool {
        return self.major != other.major or self.minor != other.minor or self.patch != other.patch;
    }

    /// __lt__ - version comparison
    pub fn __lt__(self: *const Version, other: *const Version) bool {
        if (self.major != other.major) return self.major < other.major;
        if (self.minor != other.minor) return self.minor < other.minor;
        return self.patch < other.patch;
    }

    /// __le__ - less than or equal
    pub fn __le__(self: *const Version, other: *const Version) bool {
        return self.__lt__(other) or self.__eq__(other);
    }

    /// __gt__ - greater than (independent definition)
    pub fn __gt__(self: *const Version, other: *const Version) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        return self.patch > other.patch;
    }

    /// __ge__ - greater than or equal (independent definition)
    pub fn __ge__(self: *const Version, other: *const Version) bool {
        return self.__gt__(other) or self.__eq__(other);
    }

    /// Check if this is a major version (minor and patch are 0)
    pub fn is_major(self: *const Version) bool {
        return self.minor == 0 and self.patch == 0;
    }

    /// Check if compatible with another version (same major)
    pub fn is_compatible(self: *const Version, other: *const Version) bool {
        return self.major == other.major;
    }
};

// ============================================================================
// BitSet - demonstrates __bool__, __and__, __or__, __xor__, __invert__, __lshift__, __rshift__
// ============================================================================

/// A simple bitset that demonstrates bitwise operators and __bool__
const BitSet = struct {
    bits: u64,

    pub fn __new__(bits: u64) BitSet {
        return .{ .bits = bits };
    }

    pub fn __repr__(self: *const BitSet) []const u8 {
        _ = self;
        return "BitSet(...)";
    }

    /// __bool__ - returns true if any bit is set
    pub fn __bool__(self: *const BitSet) bool {
        return self.bits != 0;
    }

    /// __and__ - bitwise AND
    pub fn __and__(self: *const BitSet, other: *const BitSet) BitSet {
        return .{ .bits = self.bits & other.bits };
    }

    /// __or__ - bitwise OR
    pub fn __or__(self: *const BitSet, other: *const BitSet) BitSet {
        return .{ .bits = self.bits | other.bits };
    }

    /// __xor__ - bitwise XOR
    pub fn __xor__(self: *const BitSet, other: *const BitSet) BitSet {
        return .{ .bits = self.bits ^ other.bits };
    }

    /// __invert__ - bitwise NOT
    pub fn __invert__(self: *const BitSet) BitSet {
        return .{ .bits = ~self.bits };
    }

    /// __lshift__ - left shift
    pub fn __lshift__(self: *const BitSet, other: *const BitSet) BitSet {
        const shift: u6 = @intCast(@min(other.bits, 63));
        return .{ .bits = self.bits << shift };
    }

    /// __rshift__ - right shift
    pub fn __rshift__(self: *const BitSet, other: *const BitSet) BitSet {
        const shift: u6 = @intCast(@min(other.bits, 63));
        return .{ .bits = self.bits >> shift };
    }

    /// Get the raw bits
    pub fn get_bits(self: *const BitSet) u64 {
        return self.bits;
    }

    /// Count set bits
    pub fn count(self: *const BitSet) i64 {
        return @intCast(@popCount(self.bits));
    }

    // In-place operators
    /// __iadd__ - in-place OR (add bits)
    pub fn __iadd__(self: *BitSet, other: *const BitSet) void {
        self.bits |= other.bits;
    }

    /// __isub__ - in-place AND NOT (remove bits)
    pub fn __isub__(self: *BitSet, other: *const BitSet) void {
        self.bits &= ~other.bits;
    }

    /// __iand__ - in-place AND
    pub fn __iand__(self: *BitSet, other: *const BitSet) void {
        self.bits &= other.bits;
    }

    /// __ior__ - in-place OR
    pub fn __ior__(self: *BitSet, other: *const BitSet) void {
        self.bits |= other.bits;
    }

    /// __ixor__ - in-place XOR
    pub fn __ixor__(self: *BitSet, other: *const BitSet) void {
        self.bits ^= other.bits;
    }

    /// __ilshift__ - in-place left shift
    pub fn __ilshift__(self: *BitSet, other: *const BitSet) void {
        const shift: u6 = @intCast(@min(other.bits, 63));
        self.bits <<= shift;
    }

    /// __irshift__ - in-place right shift
    pub fn __irshift__(self: *BitSet, other: *const BitSet) void {
        const shift: u6 = @intCast(@min(other.bits, 63));
        self.bits >>= shift;
    }
};

// ============================================================================
// PowerNumber - demonstrates __pow__, __pos__, __abs__, __int__, __float__, __index__
// ============================================================================

/// A number type that demonstrates power and coercion operators
const PowerNumber = struct {
    value: f64,

    pub fn __new__(value: f64) PowerNumber {
        return .{ .value = value };
    }

    pub fn __repr__(self: *const PowerNumber) []const u8 {
        _ = self;
        return "PowerNumber(...)";
    }

    /// __pow__ - power operator
    pub fn __pow__(self: *const PowerNumber, other: *const PowerNumber) PowerNumber {
        return .{ .value = std.math.pow(f64, self.value, other.value) };
    }

    /// __pos__ - unary positive (returns copy)
    pub fn __pos__(self: *const PowerNumber) PowerNumber {
        return .{ .value = self.value };
    }

    /// __abs__ - absolute value
    pub fn __abs__(self: *const PowerNumber) PowerNumber {
        return .{ .value = @abs(self.value) };
    }

    /// __int__ - convert to int
    pub fn __int__(self: *const PowerNumber) i64 {
        return @intFromFloat(self.value);
    }

    /// __float__ - convert to float
    pub fn __float__(self: *const PowerNumber) f64 {
        return self.value;
    }

    /// __complex__ - convert to complex (value + 0j)
    pub fn __complex__(self: *const PowerNumber) pyoz.Complex {
        return pyoz.Complex.init(self.value, 0.0);
    }

    /// __index__ - convert to index (for use in slicing, etc.)
    pub fn __index__(self: *const PowerNumber) i64 {
        return @intFromFloat(self.value);
    }

    /// __bool__ - true if non-zero
    pub fn __bool__(self: *const PowerNumber) bool {
        return self.value != 0.0;
    }
};

// ============================================================================
// Adder - demonstrates __call__ (callable instances)
// ============================================================================

/// A callable object that adds a fixed value to its argument
const Adder = struct {
    value: i64,

    pub fn __new__(value: i64) Adder {
        return .{ .value = value };
    }

    pub fn __repr__(self: *const Adder) []const u8 {
        _ = self;
        return "Adder(...)";
    }

    /// __call__ - makes instances callable like functions
    /// Usage: adder = Adder(10); adder(5) -> 15
    pub fn __call__(self: *const Adder, x: i64) i64 {
        return self.value + x;
    }

    /// Get the stored value
    pub fn get_value(self: *const Adder) i64 {
        return self.value;
    }
};

// ============================================================================
// Multiplier - demonstrates __call__ with multiple args
// ============================================================================

/// A callable object that multiplies arguments by a factor
const Multiplier = struct {
    factor: f64,

    pub fn __new__(factor: f64) Multiplier {
        return .{ .factor = factor };
    }

    pub fn __repr__(self: *const Multiplier) []const u8 {
        _ = self;
        return "Multiplier(...)";
    }

    /// __call__ with two arguments
    /// Usage: mult = Multiplier(2.0); mult(3.0, 4.0) -> 14.0 (2*(3+4))
    pub fn __call__(self: *const Multiplier, a: f64, b: f64) f64 {
        return self.factor * (a + b);
    }
};

// ============================================================================
// TypedAttribute - A descriptor that enforces type and range constraints
// ============================================================================

/// A descriptor that stores a value with min/max bounds
/// Usage: Create as class attribute, then access on instances
const TypedAttribute = struct {
    value: f64,
    min_val: f64,
    max_val: f64,
    name: [32]u8,
    name_len: usize,

    pub fn __new__(min_val: f64, max_val: f64) TypedAttribute {
        return .{
            .value = min_val, // Default to minimum
            .min_val = min_val,
            .max_val = max_val,
            .name = undefined,
            .name_len = 0,
        };
    }

    pub fn __repr__(self: *const TypedAttribute) []const u8 {
        _ = self;
        return "TypedAttribute(...)";
    }

    /// __get__ - called when attribute is accessed
    /// Returns the stored value (or self if accessed on class)
    pub fn __get__(self: *const TypedAttribute, obj: ?*pyoz.PyObject) f64 {
        _ = obj; // Could use to return self when obj is null (class access)
        return self.value;
    }

    /// __set__ - called when attribute is assigned
    /// Clamps value to [min_val, max_val]
    pub fn __set__(self: *TypedAttribute, obj: ?*pyoz.PyObject, value: f64) void {
        _ = obj;
        self.value = @max(self.min_val, @min(self.max_val, value));
    }

    /// __delete__ - called when attribute is deleted
    /// Resets value to the minimum (default)
    pub fn __delete__(self: *TypedAttribute, obj: ?*pyoz.PyObject) void {
        _ = obj;
        self.value = self.min_val;
    }

    /// Get the current bounds
    pub fn get_bounds(self: *const TypedAttribute) struct { f64, f64 } {
        return .{ self.min_val, self.max_val };
    }
};

// ============================================================================
// ReversibleList - demonstrates __reversed__
// ============================================================================

/// A simple list that supports reversed iteration
/// Uses a single type with a reverse_mode flag to work around converter limitations
const ReversibleList = struct {
    data: [8]i64,
    len: usize,
    iter_index: usize,
    reverse_mode: bool,

    pub fn __new__(a: i64, b: i64, c: i64) ReversibleList {
        var list = ReversibleList{
            .data = [_]i64{0} ** 8,
            .len = 3,
            .iter_index = 0,
            .reverse_mode = false,
        };
        list.data[0] = a;
        list.data[1] = b;
        list.data[2] = c;
        return list;
    }

    pub fn __repr__(self: *const ReversibleList) []const u8 {
        _ = self;
        return "ReversibleList(...)";
    }

    pub fn __len__(self: *const ReversibleList) usize {
        return self.len;
    }

    pub fn __getitem__(self: *const ReversibleList, index: i64) !i64 {
        const idx: usize = if (index < 0)
            @intCast(@as(i64, @intCast(self.len)) + index)
        else
            @intCast(index);

        if (idx >= self.len) {
            return error.IndexOutOfBounds;
        }
        return self.data[idx];
    }

    /// __iter__ - return self, preserving reverse_mode
    pub fn __iter__(self: *ReversibleList) *ReversibleList {
        self.iter_index = 0;
        // Don't reset reverse_mode - let __reversed__ control it
        return self;
    }

    /// __next__ - get next item based on reverse_mode
    pub fn __next__(self: *ReversibleList) ?i64 {
        if (self.iter_index >= self.len) {
            // Reset reverse_mode after iteration completes
            self.reverse_mode = false;
            return null;
        }
        const idx = if (self.reverse_mode)
            self.len - 1 - self.iter_index
        else
            self.iter_index;
        self.iter_index += 1;
        return self.data[idx];
    }

    /// __reversed__ - return self configured for reverse iteration
    /// This sets reverse_mode=true before __iter__ is called
    pub fn __reversed__(self: *ReversibleList) *ReversibleList {
        self.reverse_mode = true;
        self.iter_index = 0;
        return self;
    }

    /// Append a value
    pub fn append(self: *ReversibleList, value: i64) !void {
        if (self.len >= 8) {
            return error.ListFull;
        }
        self.data[self.len] = value;
        self.len += 1;
    }

    /// Check if in reverse mode (for testing)
    pub fn is_reversed(self: *const ReversibleList) bool {
        return self.reverse_mode;
    }
};

// ============================================================================
// DynamicObject - demonstrates __getattr__, __setattr__, __delattr__
// ============================================================================

/// A dynamic object that stores arbitrary attributes in a hash map
const DynamicObject = struct {
    // Fixed storage for dynamic attributes (simplified - real impl would use allocator)
    attr_names: [16][32]u8,
    attr_values: [16]i64,
    attr_count: usize,

    pub fn __new__() DynamicObject {
        return .{
            .attr_names = undefined,
            .attr_values = undefined,
            .attr_count = 0,
        };
    }

    pub fn __repr__(self: *const DynamicObject) []const u8 {
        _ = self;
        return "DynamicObject(...)";
    }

    /// __getattr__ - called when attribute is not found via normal lookup
    pub fn __getattr__(self: *const DynamicObject, name: []const u8) !i64 {
        // Search for the attribute
        for (0..self.attr_count) |i| {
            const stored_name = self.attr_names[i][0..name.len];
            if (std.mem.eql(u8, stored_name, name)) {
                return self.attr_values[i];
            }
        }
        return error.AttributeNotFound;
    }

    /// __setattr__ - called for ALL attribute assignments
    /// We store everything as i64 for simplicity
    pub fn __setattr__(self: *DynamicObject, name: []const u8, value: *pyoz.PyObject) void {
        // Try to convert value to i64
        const int_val = pyoz.Conversions.fromPy(i64, value) catch 0;

        // Check if attribute already exists
        for (0..self.attr_count) |i| {
            const stored_name = self.attr_names[i][0..name.len];
            if (std.mem.eql(u8, stored_name, name)) {
                self.attr_values[i] = int_val;
                return;
            }
        }

        // Add new attribute if space available
        if (self.attr_count < 16 and name.len < 32) {
            @memcpy(self.attr_names[self.attr_count][0..name.len], name);
            // Zero out the rest to ensure clean comparison
            for (name.len..32) |j| {
                self.attr_names[self.attr_count][j] = 0;
            }
            self.attr_values[self.attr_count] = int_val;
            self.attr_count += 1;
        }
    }

    /// __delattr__ - called when deleting an attribute
    pub fn __delattr__(self: *DynamicObject, name: []const u8) !void {
        for (0..self.attr_count) |i| {
            const stored_name = self.attr_names[i][0..name.len];
            if (std.mem.eql(u8, stored_name, name)) {
                // Shift remaining attributes
                var j = i;
                while (j < self.attr_count - 1) : (j += 1) {
                    self.attr_names[j] = self.attr_names[j + 1];
                    self.attr_values[j] = self.attr_values[j + 1];
                }
                self.attr_count -= 1;
                return;
            }
        }
        return error.AttributeNotFound;
    }

    /// Get the count of dynamic attributes
    pub fn count(self: *const DynamicObject) usize {
        return self.attr_count;
    }

    /// List all attribute names (for debugging)
    pub fn keys(self: *const DynamicObject) []const u8 {
        _ = self;
        return "use iteration"; // Simplified
    }
};

// ============================================================================
// Vector - demonstrates reflected operators (__radd__, __rmul__, etc.)
// ============================================================================

/// A vector type that can be multiplied/added with Python scalars using reflected ops
const Vector = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn __new__(x: f64, y: f64, z: f64) Vector {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn __repr__(self: *const Vector) []const u8 {
        _ = self;
        return "Vector(...)";
    }

    /// __add__ - vector + vector
    pub fn __add__(self: *const Vector, other: *const Vector) Vector {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }

    /// __radd__ - scalar + vector (reflected add)
    /// Called when: 5 + vector (left operand doesn't support the operation)
    pub fn __radd__(self: *const Vector, other: *pyoz.PyObject) Vector {
        // Try to convert the other object to a float
        const scalar = pyoz.Conversions.fromPy(f64, other) catch return self.*;
        return .{ .x = self.x + scalar, .y = self.y + scalar, .z = self.z + scalar };
    }

    /// __mul__ - vector * vector (element-wise)
    pub fn __mul__(self: *const Vector, other: *const Vector) Vector {
        return .{ .x = self.x * other.x, .y = self.y * other.y, .z = self.z * other.z };
    }

    /// __rmul__ - scalar * vector (reflected multiply)
    /// Called when: 3.0 * vector
    pub fn __rmul__(self: *const Vector, other: *pyoz.PyObject) Vector {
        const scalar = pyoz.Conversions.fromPy(f64, other) catch return self.*;
        return .{ .x = self.x * scalar, .y = self.y * scalar, .z = self.z * scalar };
    }

    /// __sub__ - vector - vector
    pub fn __sub__(self: *const Vector, other: *const Vector) Vector {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }

    /// __rsub__ - scalar - vector (reflected subtract)
    /// Called when: 10 - vector
    pub fn __rsub__(self: *const Vector, other: *pyoz.PyObject) Vector {
        const scalar = pyoz.Conversions.fromPy(f64, other) catch return self.*;
        return .{ .x = scalar - self.x, .y = scalar - self.y, .z = scalar - self.z };
    }

    /// Get magnitude
    pub fn magnitude(self: *const Vector) f64 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    /// Dot product
    pub fn dot(self: *const Vector, other: *const Vector) f64 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    /// __matmul__ - matrix multiplication operator (@)
    /// For vectors, this computes the cross product
    pub fn __matmul__(self: *const Vector, other: *const Vector) Vector {
        // Cross product: a × b = (a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x)
        return .{
            .x = self.y * other.z - self.z * other.y,
            .y = self.z * other.x - self.x * other.z,
            .z = self.x * other.y - self.y * other.x,
        };
    }

    /// __rmatmul__ - reflected matrix multiplication operator
    /// Called when: other @ vector (and other doesn't support @)
    pub fn __rmatmul__(self: *const Vector, other: *pyoz.PyObject) Vector {
        // Try to interpret other as a scalar for scalar @ vector (unusual but demonstrable)
        const scalar = pyoz.Conversions.fromPy(f64, other) catch return self.*;
        return .{ .x = self.x * scalar, .y = self.y * scalar, .z = self.z * scalar };
    }

    /// __imatmul__ - in-place matrix multiplication operator (@=)
    /// For demonstration, we'll make this compute cross product with another vector
    pub fn __imatmul__(self: *Vector, other: *const Vector) void {
        const new_x = self.y * other.z - self.z * other.y;
        const new_y = self.z * other.x - self.x * other.z;
        const new_z = self.x * other.y - self.y * other.x;
        self.x = new_x;
        self.y = new_y;
        self.z = new_z;
    }
};

// ============================================================================
// GC-enabled class example - Container with Python object references
// ============================================================================

/// A container that holds references to Python objects
/// Demonstrates __traverse__ and __clear__ for GC integration
const Container = struct {
    /// The stored Python object (can create reference cycles)
    stored: ?*pyoz.PyObject,
    name: [32]u8,
    name_len: usize,

    pub fn __new__(name: []const u8) Container {
        var c = Container{
            .stored = null,
            .name = undefined,
            .name_len = @min(name.len, 32),
        };
        @memcpy(c.name[0..c.name_len], name[0..c.name_len]);
        return c;
    }

    pub fn __repr__(self: *const Container) []const u8 {
        _ = self;
        return "Container(...)";
    }

    /// Store a Python object (increments refcount)
    pub fn store(self: *Container, obj: *pyoz.PyObject) void {
        // Release old reference if any
        if (self.stored) |old| {
            pyoz.py.Py_DecRef(old);
        }
        // Store new reference (incref)
        pyoz.py.Py_IncRef(obj);
        self.stored = obj;
    }

    /// Get the stored object (returns new reference)
    pub fn get(self: *const Container) ?*pyoz.PyObject {
        if (self.stored) |obj| {
            pyoz.py.Py_IncRef(obj);
            return obj;
        }
        return null;
    }

    /// Clear the stored object
    pub fn clear_stored(self: *Container) void {
        if (self.stored) |obj| {
            pyoz.py.Py_DecRef(obj);
            self.stored = null;
        }
    }

    /// Check if something is stored
    pub fn has_value(self: *const Container) bool {
        return self.stored != null;
    }

    /// Get the container name
    pub fn get_name(self: *const Container) []const u8 {
        return self.name[0..self.name_len];
    }

    // ========== GC Integration ==========

    /// __traverse__ - Called by GC to discover references
    /// We must visit all PyObject references we hold
    pub fn __traverse__(self: *Container, visitor: pyoz.GCVisitor) c_int {
        // Visit the stored object if we have one
        const ret = visitor.call(self.stored);
        if (ret != 0) return ret;
        return 0;
    }

    /// __clear__ - Called by GC to break reference cycles
    /// We must release all PyObject references
    pub fn __clear__(self: *Container) void {
        if (self.stored) |obj| {
            pyoz.py.Py_DecRef(obj);
            self.stored = null;
        }
    }
};

// ============================================================================
// Flexible - demonstrates __dict__ support for dynamic attributes
// ============================================================================

/// A class that allows dynamic attributes via __dict__
/// This is useful when you want Python-style dynamic attribute assignment
const Flexible = struct {
    /// Enable features like PyO3's #[pyclass(dict, weakref)]
    pub const __features__ = .{ .dict = true, .weakref = true };

    /// A fixed Zig field
    value: i64,

    pub fn __new__(value: i64) Flexible {
        return .{ .value = value };
    }

    pub fn __repr__(self: *const Flexible) []const u8 {
        _ = self;
        return "Flexible(...)";
    }

    /// Get the fixed value
    pub fn get_value(self: *const Flexible) i64 {
        return self.value;
    }

    /// Set the fixed value
    pub fn set_value(self: *Flexible, new_value: i64) void {
        self.value = new_value;
    }

    /// Double the value
    pub fn double(self: *Flexible) void {
        self.value *= 2;
    }
};

// ============================================================================
// ValidatedProp - reproduces bug: computed property setter returning ?void
// ============================================================================

const ValidatedProp = struct {
    _value: u64,

    pub fn __new__() ValidatedProp {
        return .{ ._value = 0 };
    }

    pub fn get_value(self: *const ValidatedProp) ?u64 {
        if (self._value == 999) return pyoz.raiseRuntimeError("value is in error state");
        return self._value;
    }

    pub fn set_value(self: *ValidatedProp, data: u64) ?void {
        if (data == 0) return pyoz.raiseValueError("`value` cannot be set to 0");
        self._value = data;
        return;
    }
};

// ============================================================================
// Enum Example - Color enum that becomes Python IntEnum
// ============================================================================

/// A color enum that will be exposed as Python IntEnum
const Color = enum(i32) {
    Red = 1,
    Green = 2,
    Blue = 3,
    Yellow = 4,
    Cyan = 5,
    Magenta = 6,
};

/// HTTP status codes as enum
const HttpStatus = enum(i32) {
    OK = 200,
    Created = 201,
    BadRequest = 400,
    NotFound = 404,
    InternalServerError = 500,
};

/// Task status as a string enum - field names become string values
const TaskStatus = enum {
    pending,
    in_progress,
    completed,
    cancelled,
};

/// Log levels as a string enum
const LogLevel = enum {
    debug,
    info,
    warning,
    @"error", // Note: 'error' is a Zig keyword, so we use @"error"
    critical,
};

// ============================================================================
// FrozenPoint - demonstrates frozen (immutable) classes
// ============================================================================

/// An immutable 2D point - attributes cannot be changed after creation
const FrozenPoint = struct {
    /// Mark this class as frozen (immutable)
    pub const __frozen__: bool = true;

    x: f64,
    y: f64,

    pub fn __repr__(self: *const FrozenPoint) []const u8 {
        _ = self;
        return "FrozenPoint(...)";
    }

    /// __hash__ - immutable objects should be hashable
    /// This allows FrozenPoint to be used in sets and as dict keys
    pub fn __hash__(self: *const FrozenPoint) i64 {
        // Simple hash combining x and y coordinates
        // Using bit manipulation to create a reasonable hash
        const x_bits: u64 = @bitCast(self.x);
        const y_bits: u64 = @bitCast(self.y);
        // Combine using XOR and bit rotation
        const combined = x_bits ^ (y_bits *% 31);
        return @bitCast(combined);
    }

    /// __eq__ - required for proper hash behavior
    pub fn __eq__(self: *const FrozenPoint, other: *const FrozenPoint) bool {
        return self.x == other.x and self.y == other.y;
    }

    /// Calculate distance from origin (methods still work on frozen classes)
    pub fn magnitude(self: *const FrozenPoint) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    /// Create a new point with scaled coordinates (returns new instance)
    pub fn scale(self: *const FrozenPoint, factor: f64) FrozenPoint {
        return .{ .x = self.x * factor, .y = self.y * factor };
    }

    /// Static constructor
    pub fn origin() FrozenPoint {
        return .{ .x = 0.0, .y = 0.0 };
    }
};

// ============================================================================
// Circle - demonstrates class attributes
// ============================================================================

/// A circle with class-level constants
const Circle = struct {
    radius: f64,

    // Class attributes - these are shared by all instances
    // Use "classattr_" prefix to define class-level attributes
    pub const classattr_PI: f64 = 3.14159265358979;
    pub const classattr_UNIT_RADIUS: f64 = 1.0;
    pub const classattr_DEFAULT_COLOR: []const u8 = "red";
    pub const classattr_MAX_RADIUS: i64 = 1000;

    pub fn __repr__(self: *const Circle) []const u8 {
        _ = self;
        return "Circle(...)";
    }

    /// Calculate area using the class attribute PI
    pub fn area(self: *const Circle) f64 {
        return classattr_PI * self.radius * self.radius;
    }

    /// Calculate circumference
    pub fn circumference(self: *const Circle) f64 {
        return 2.0 * classattr_PI * self.radius;
    }

    /// Static method to create a unit circle
    pub fn unit() Circle {
        return .{ .radius = classattr_UNIT_RADIUS };
    }
};

// ============================================================================
// Stack - demonstrates inheritance (extends Python list)
// ============================================================================

/// A stack class that extends Python's list
const Stack = struct {
    // Inherit from Python's list type
    pub const __base__ = pyoz.bases.list;

    // Note: When extending Python types, we don't define our own fields
    // The base class handles the data storage

    pub const __doc__: [*:0]const u8 = "A stack (LIFO) that extends Python list";

    /// Push an item onto the stack (alias for append)
    pub fn push(self: *Stack, item: *pyoz.PyObject) void {
        _ = pyoz.py.PyList_Append(pyoz.object(self), item);
    }

    /// Pop an item from the stack
    pub fn pop_item(self: *Stack) ?*pyoz.PyObject {
        const len = pyoz.py.PyList_Size(pyoz.object(self));
        if (len <= 0) {
            pyoz.py.PyErr_SetString(pyoz.py.PyExc_IndexError(), "pop from empty stack");
            return null;
        }
        // Get the last item
        const item = pyoz.py.PyList_GetItem(pyoz.object(self), len - 1);
        if (item) |i| {
            pyoz.py.Py_IncRef(i);
            // Remove it
            _ = pyoz.py.PyList_SetSlice(pyoz.object(self), len - 1, len, null);
            return i;
        }
        return null;
    }

    /// Peek at the top item without removing it
    pub fn peek(self: *const Stack) ?*pyoz.PyObject {
        const len = pyoz.py.PyList_Size(pyoz.object(self));
        if (len <= 0) {
            pyoz.py.PyErr_SetString(pyoz.py.PyExc_IndexError(), "peek at empty stack");
            return null;
        }
        const item = pyoz.py.PyList_GetItem(pyoz.object(self), len - 1);
        if (item) |i| {
            pyoz.py.Py_IncRef(i);
            return i;
        }
        return null;
    }

    /// Check if stack is empty
    pub fn is_empty(self: *const Stack) bool {
        return pyoz.py.PyList_Size(pyoz.object(self)) == 0;
    }

    /// Get stack size
    pub fn stack_size(self: *const Stack) i64 {
        return pyoz.py.PyList_Size(pyoz.object(self));
    }
};

// ============================================================================
// DefaultDict - demonstrates __missing__ for dict subclasses
// ============================================================================

/// A dict that returns a default value for missing keys
const DefaultDict = struct {
    // Inherit from Python's dict type
    pub const __base__ = pyoz.bases.dict;

    pub const __doc__: [*:0]const u8 = "A dict that returns a default value for missing keys";

    /// __missing__ - called when a key is not found
    /// Returns the key itself as a string (for demonstration)
    pub fn __missing__(self: *DefaultDict, key: *pyoz.PyObject) ?*pyoz.PyObject {
        // For this example, we just return the key converted to string
        // In a real implementation, you might want to store a default factory
        const str_obj = pyoz.py.PyObject_Str(key);
        if (str_obj) |s| {
            // Optionally store it in the dict
            _ = pyoz.py.PyDict_SetItem(pyoz.object(self), key, s);
            return s;
        }
        return null;
    }

    /// Get number of items
    pub fn size(self: *const DefaultDict) i64 {
        return pyoz.py.PyDict_Size(pyoz.object(self));
    }
};

// ============================================================================
// Numpy / BufferView examples - Zero-copy array operations
// ============================================================================

/// Sum all elements in a numpy array (zero-copy, read-only)
fn numpy_sum(arr: pyoz.BufferView(f64)) f64 {
    var total: f64 = 0;
    for (arr.data) |v| {
        total += v;
    }
    return total;
}

/// Get element at 2D index - tests get2D error handling
/// Returns error.DimensionMismatch if array is not 2D
fn numpy_get_2d(arr: pyoz.BufferView(f64), row: usize, col: usize) !f64 {
    return arr.get2D(row, col);
}

/// Get element at 2D index for i64 arrays - tests stride handling
fn buffer_get_2d_i64(arr: pyoz.BufferView(i64), row: usize, col: usize) !i64 {
    return arr.get2D(row, col);
}

/// Calculate mean of a numpy array
fn numpy_mean(arr: pyoz.BufferView(f64)) ?f64 {
    if (arr.len() == 0) return null;
    var total: f64 = 0;
    for (arr.data) |v| {
        total += v;
    }
    return total / @as(f64, @floatFromInt(arr.len()));
}

/// Find min and max of a numpy array, returns (min, max) tuple
fn numpy_minmax(arr: pyoz.BufferView(f64)) ?struct { f64, f64 } {
    if (arr.len() == 0) return null;
    var min_val = arr.data[0];
    var max_val = arr.data[0];
    for (arr.data) |v| {
        if (v < min_val) min_val = v;
        if (v > max_val) max_val = v;
    }
    return .{ min_val, max_val };
}

/// Compute dot product of two numpy arrays
fn numpy_dot(a: pyoz.BufferView(f64), b: pyoz.BufferView(f64)) ?f64 {
    if (a.len() != b.len()) {
        pyoz.py.PyErr_SetString(pyoz.py.PyExc_ValueError(), "Arrays must have same length");
        return null;
    }
    var result: f64 = 0;
    for (a.data, b.data) |x, y| {
        result += x * y;
    }
    return result;
}

/// Scale all elements in a numpy array in-place (zero-copy, mutable)
fn numpy_scale(arr: pyoz.BufferViewMut(f64), factor: f64) void {
    for (arr.data) |*v| {
        v.* *= factor;
    }
}

/// Add a scalar to all elements in-place
fn numpy_add_scalar(arr: pyoz.BufferViewMut(f64), scalar: f64) void {
    for (arr.data) |*v| {
        v.* += scalar;
    }
}

/// Fill array with a value in-place
fn numpy_fill(arr: pyoz.BufferViewMut(f64), value: f64) void {
    arr.fill(value);
}

/// Normalize array in-place (divide by max absolute value)
fn numpy_normalize(arr: pyoz.BufferViewMut(f64)) void {
    // Calculate Euclidean norm (magnitude)
    var sum_sq: f64 = 0;
    for (arr.data) |v| {
        sum_sq += v * v;
    }
    const magnitude = @sqrt(sum_sq);
    if (magnitude > 0) {
        for (arr.data) |*v| {
            v.* /= magnitude;
        }
    }
}

/// Element-wise multiply two arrays, storing result in first array.
/// Returns ?bool (optional bool) to allow raising exceptions:
///   - return true  -> Python True (success)
///   - return false -> Python False (failure without exception)
///   - return null  -> Check PyErr_Occurred(), raise exception if set, else Python None
fn numpy_multiply_inplace(a: pyoz.BufferViewMut(f64), b: pyoz.BufferView(f64)) ?bool {
    if (a.len() != b.len()) {
        // Set exception and return null to raise it
        pyoz.py.PyErr_SetString(pyoz.py.PyExc_ValueError(), "Arrays must have same length");
        return null;
    }
    for (a.data, b.data) |*x, y| {
        x.* *= y;
    }
    return true;
}

/// Sum integers in an int64 numpy array
fn numpy_sum_int(arr: pyoz.BufferView(i64)) i64 {
    var total: i64 = 0;
    for (arr.data) |v| {
        total +%= v; // Use wrapping add to avoid overflow
    }
    return total;
}

/// Get array shape info as (rows, cols) for 2D arrays
fn numpy_shape_info(arr: pyoz.BufferView(f64)) struct { usize, usize } {
    return .{ arr.rows(), arr.cols() };
}

/// Apply ReLU (max(0, x)) in-place - common neural network operation
fn numpy_relu(arr: pyoz.BufferViewMut(f64)) void {
    for (arr.data) |*v| {
        if (v.* < 0) v.* = 0;
    }
}

/// Apply softmax normalization in-place (for 1D arrays)
fn numpy_softmax(arr: pyoz.BufferViewMut(f64)) void {
    // Find max for numerical stability
    var max_val: f64 = arr.data[0];
    for (arr.data) |v| {
        if (v > max_val) max_val = v;
    }

    // Compute exp(x - max) and sum
    var sum: f64 = 0;
    for (arr.data) |*v| {
        v.* = @exp(v.* - max_val);
        sum += v.*;
    }

    // Normalize
    for (arr.data) |*v| {
        v.* /= sum;
    }
}

/// Compute variance of array
fn numpy_variance(arr: pyoz.BufferView(f64)) ?f64 {
    const n = arr.len();
    if (n == 0) return null;

    // Calculate mean
    var sum: f64 = 0;
    for (arr.data) |v| sum += v;
    const mean = sum / @as(f64, @floatFromInt(n));

    // Calculate variance
    var variance: f64 = 0;
    for (arr.data) |v| {
        const diff = v - mean;
        variance += diff * diff;
    }
    return variance / @as(f64, @floatFromInt(n));
}

/// Compute standard deviation
fn numpy_std(arr: pyoz.BufferView(f64)) ?f64 {
    if (numpy_variance(arr)) |variance| {
        return @sqrt(variance);
    }
    return null;
}

/// Clamp all values to [min_val, max_val] in-place
fn numpy_clamp(arr: pyoz.BufferViewMut(f64), min_val: f64, max_val: f64) void {
    for (arr.data) |*v| {
        if (v.* < min_val) v.* = min_val;
        if (v.* > max_val) v.* = max_val;
    }
}

// ============================================================================
// Complex Number Array Functions (numpy complex128)
// ============================================================================

/// Sum complex128 array elements
fn numpy_complex_sum(arr: pyoz.BufferView(pyoz.Complex)) pyoz.Complex {
    var result = pyoz.Complex.init(0, 0);
    for (arr.data) |v| {
        result = result.add(v);
    }
    return result;
}

/// Calculate magnitudes of complex array, store in output array
fn numpy_complex_magnitudes(arr: pyoz.BufferView(pyoz.Complex), out: pyoz.BufferViewMut(f64)) ?bool {
    if (arr.len() != out.len()) {
        pyoz.py.PyErr_SetString(pyoz.py.PyExc_ValueError(), "Arrays must have same length");
        return null;
    }
    for (arr.data, out.data) |c, *m| {
        m.* = c.magnitude();
    }
    return true;
}

/// Conjugate all elements in-place
fn numpy_complex_conjugate(arr: pyoz.BufferViewMut(pyoz.Complex)) void {
    for (arr.data) |*v| {
        v.* = v.conjugate();
    }
}

/// Scale complex array by a real factor in-place
fn numpy_complex_scale(arr: pyoz.BufferViewMut(pyoz.Complex), factor: f64) void {
    for (arr.data) |*v| {
        v.real *= factor;
        v.imag *= factor;
    }
}

/// Dot product of two complex arrays (with conjugate of first)
fn numpy_complex_dot(a: pyoz.BufferView(pyoz.Complex), b: pyoz.BufferView(pyoz.Complex)) ?pyoz.Complex {
    if (a.len() != b.len()) {
        pyoz.py.PyErr_SetString(pyoz.py.PyExc_ValueError(), "Arrays must have same length");
        return null;
    }
    var result = pyoz.Complex.init(0, 0);
    for (a.data, b.data) |x, y| {
        // Hermitian dot product: sum of conj(a[i]) * b[i]
        result = result.add(x.conjugate().mul(y));
    }
    return result;
}

// ============================================================================
// Complex32 Array Functions (numpy complex64)
// ============================================================================

/// Sum complex64 array elements
fn numpy_complex64_sum(arr: pyoz.BufferView(pyoz.Complex32)) pyoz.Complex {
    var result = pyoz.Complex32.init(0, 0);
    for (arr.data) |v| {
        result = result.add(v);
    }
    return result.toComplex();
}

// ============================================================================
// Temperature - demonstrates pyoz.property() API
// ============================================================================

/// A temperature class that demonstrates the pyoz.property() API
/// for cleaner property definitions with getters, setters, and docstrings
const Temperature = struct {
    _celsius: f64,

    const Self = @This();

    pub fn __new__(initial_celsius: f64) Temperature {
        return .{ ._celsius = initial_celsius };
    }

    pub fn __repr__(self: *const Temperature) []const u8 {
        _ = self;
        return "Temperature(...)";
    }

    /// Property using pyoz.property() - celsius with validation
    pub const celsius = pyoz.property(.{
        .get = struct {
            fn get(self: *const Self) f64 {
                return self._celsius;
            }
        }.get,
        .set = struct {
            fn set(self: *Self, value: f64) void {
                // Clamp to absolute zero minimum
                self._celsius = if (value < -273.15) -273.15 else value;
            }
        }.set,
        .doc = "Temperature in Celsius (clamped to >= -273.15)",
    });

    /// Property using pyoz.property() - fahrenheit (computed, read-write)
    pub const fahrenheit = pyoz.property(.{
        .get = struct {
            fn get(self: *const Self) f64 {
                return self._celsius * 9.0 / 5.0 + 32.0;
            }
        }.get,
        .set = struct {
            fn set(self: *Self, value: f64) void {
                self._celsius = (value - 32.0) * 5.0 / 9.0;
            }
        }.set,
        .doc = "Temperature in Fahrenheit",
    });

    /// Property using pyoz.property() - kelvin (read-only, no setter)
    pub const kelvin = pyoz.property(.{
        .get = struct {
            fn get(self: *const Self) f64 {
                return self._celsius + 273.15;
            }
        }.get,
        .doc = "Temperature in Kelvin (read-only)",
    });

    /// Check if temperature is below freezing
    pub fn is_freezing(self: *const Self) bool {
        return self._celsius < 0.0;
    }

    /// Check if temperature is boiling (at sea level)
    pub fn is_boiling(self: *const Self) bool {
        return self._celsius >= 100.0;
    }
};

// ============================================================================
// Private fields example - demonstrates underscore prefix convention
// ============================================================================

/// Example class demonstrating private fields (underscore prefix).
/// Private fields are NOT exposed to Python as properties or __init__ args.
const PrivateFieldsExample = struct {
    pub const __doc__: [*:0]const u8 = "Example class with private fields.\n\nPrivate fields (starting with _) are not exposed to Python.";

    // PUBLIC fields - exposed to Python as properties and __init__ args
    name: []const u8,
    value: i64,

    // PRIVATE fields - NOT exposed to Python (underscore prefix)
    // These are zero-initialized and only accessible from Zig methods
    _internal_counter: i64,
    _cached_result: ?i64,

    /// Get the current internal counter value (demonstrates accessing private fields via methods)
    pub fn get_internal_counter(self: *const PrivateFieldsExample) i64 {
        return self._internal_counter;
    }

    /// Increment the internal counter and return the new value
    pub fn increment_counter(self: *PrivateFieldsExample) i64 {
        self._internal_counter += 1;
        return self._internal_counter;
    }

    /// Check if we have a cached result
    pub fn has_cached_result(self: *const PrivateFieldsExample) bool {
        return self._cached_result != null;
    }

    /// Compute and cache a result (value * 2)
    pub fn compute_and_cache(self: *PrivateFieldsExample) i64 {
        const result = self.value * 2;
        self._cached_result = result;
        return result;
    }

    /// Get cached result (returns 0 if not cached yet - use compute_and_cache to compute)
    pub fn get_cached_or_zero(self: *const PrivateFieldsExample) i64 {
        return self._cached_result orelse 0;
    }
};

// ============================================================================
// ArenaClass - demonstrates private fields with non-zero-initializable types
// (e.g. std.heap.ArenaAllocator which contains non-nullable pointers)
const ArenaClass = struct {
    value: i64,
    _arena: std.heap.ArenaAllocator,

    pub fn __new__(value: i64) ArenaClass {
        return .{
            .value = value,
            ._arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn __del__(self: *ArenaClass) void {
        self._arena.deinit();
    }

    pub fn __repr__(self: *const ArenaClass) [*:0]const u8 {
        return pyoz.fmt("ArenaClass(value={d})", .{self.value});
    }

    pub fn get_value(self: *const ArenaClass) i64 {
        return self.value;
    }

    /// Allocate a buffer using the arena and return its length
    pub fn alloc_buffer(self: *ArenaClass, size: i64) !i64 {
        const buf = try self._arena.allocator().alloc(u8, @intCast(size));
        return @intCast(buf.len);
    }
};

// ============================================================================
// Simple class with no custom __repr__ - tests default repr generation
const SimplePoint = struct {
    x: f64,
    y: f64,

    pub const __class_getitem__ = true;
    pub const __freelist__: usize = 8;
};

// ============================================================================
// Resource class - demonstrates __del__ for custom cleanup
// Simulates a C resource (file descriptor, allocated buffer, etc.)
const Resource = struct {
    handle: i64,
    _freed: bool,

    pub fn __new__(handle: i64) Resource {
        return .{ .handle = handle, ._freed = false };
    }

    pub fn __del__(self: *Resource) void {
        self._freed = true;
        self.handle = -1;
    }

    pub fn is_valid(self: *const Resource) bool {
        return self.handle >= 0 and !self._freed;
    }

    pub fn get_handle(self: *const Resource) i64 {
        return self.handle;
    }
};

// ============================================================================
// FailingResource - tests that __del__ is NOT called when __new__ fails
// This verifies Python semantics: if __new__ raises, no object was created,
// so __del__ must not run (avoids segfault on uninitialized data).
const FailingResource = struct {
    handle: i64,
    _freed: bool,

    pub fn __new__(handle: i64) ?FailingResource {
        if (handle < 0) {
            return pyoz.raiseValueError("handle must be non-negative");
        }
        return .{ .handle = handle, ._freed = false };
    }

    pub fn __del__(self: *FailingResource) void {
        // Set a global flag so tests can detect if __del__ was called
        self._freed = true;
        self.handle = -1;
    }

    pub fn is_valid(self: *const FailingResource) bool {
        return self.handle >= 0 and !self._freed;
    }
};

// ============================================================================
// FlexPoint - demonstrates optional constructor arguments
const FlexPoint = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn __new__(x: f64, y: ?f64, z: ?f64) FlexPoint {
        return .{ .x = x, .y = y orelse 0.0, .z = z orelse 0.0 };
    }
};

// ============================================================================
// Line - demonstrates cross-class references (methods that accept/return Point)
// ============================================================================

/// A line segment defined by two endpoints.
/// Demonstrates cross-class methods: methods on Line that accept/return Point instances.
const Line = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,

    /// Get the start point as a Point instance (cross-class return)
    pub fn start_point(self: *const Line) Point {
        return .{ .x = self.x1, .y = self.y1 };
    }

    /// Get the end point as a Point instance (cross-class return)
    pub fn end_point(self: *const Line) Point {
        return .{ .x = self.x2, .y = self.y2 };
    }

    /// Get the midpoint as a Point instance (cross-class return)
    pub fn midpoint(self: *const Line) Point {
        return .{ .x = (self.x1 + self.x2) / 2.0, .y = (self.y1 + self.y2) / 2.0 };
    }

    /// Create a Line from two Point instances (cross-class accept, by pointer)
    pub fn from_points(p1: *const Point, p2: *const Point) Line {
        return .{ .x1 = p1.x, .y1 = p1.y, .x2 = p2.x, .y2 = p2.y };
    }

    /// Create a Line from two Point instances passed by value (cross-class accept, by value)
    pub fn from_points_val(p1: Point, p2: Point) Line {
        return .{ .x1 = p1.x, .y1 = p1.y, .x2 = p2.x, .y2 = p2.y };
    }

    /// Calculate the length of the line segment
    pub fn length(self: *const Line) f64 {
        const dx = self.x2 - self.x1;
        const dy = self.y2 - self.y1;
        return @sqrt(dx * dx + dy * dy);
    }

    pub fn __repr__(self: *const Line) []const u8 {
        _ = self;
        return "Line(...)";
    }
};

// ============================================================================
// Test: pyoz.Ref(T) — strong cross-object references
// ============================================================================

/// Owner class — holds a value that RefChild references
const Owner = struct {
    value: i64,

    pub fn get_value(self: *const Owner) i64 {
        return self.value;
    }

    pub fn __repr__(self: *const Owner) []const u8 {
        _ = self;
        return "Owner(...)";
    }
};

/// Child class that holds a Ref to its Owner.
/// The Ref keeps the Owner alive as long as the Child exists.
const RefChild = struct {
    _owner: pyoz.Ref(Owner),
    tag: i64,

    pub fn get_owner_value(self: *const RefChild) ?i64 {
        const owner = self._owner.get(Example.registered_classes) orelse return null;
        return owner.value;
    }

    pub fn has_owner(self: *const RefChild) bool {
        return self._owner.object() != null;
    }

    pub fn __repr__(self: *const RefChild) []const u8 {
        _ = self;
        return "RefChild(...)";
    }
};

/// Function to create a RefChild that holds a reference to an Owner.
/// This is the typical pattern: a function/method receives `*const Owner`
/// (which is a pointer into the PyWrapper), and uses selfObject to get
/// the PyObject for INCREF.
fn make_ref_child(owner: *const Owner, tag: i64) RefChild {
    var child = RefChild{ .tag = tag, ._owner = .{} };
    child._owner.set(Example.selfObject(Owner, owner));
    return child;
}

/// Child class with freelist — tests that Ref is properly cleared on freelist push
const RefChildFreelist = struct {
    _owner: pyoz.Ref(Owner),
    tag: i64,

    const __freelist__ = 4;

    pub fn get_owner_value(self: *const RefChildFreelist) ?i64 {
        const owner = self._owner.get(Example.registered_classes) orelse return null;
        return owner.value;
    }

    pub fn has_owner(self: *const RefChildFreelist) bool {
        return self._owner.object() != null;
    }

    pub fn __repr__(self: *const RefChildFreelist) []const u8 {
        _ = self;
        return "RefChildFreelist(...)";
    }
};

/// Function to create a RefChildFreelist
fn make_ref_child_freelist(owner: *const Owner, tag: i64) RefChildFreelist {
    var child = RefChildFreelist{ .tag = tag, ._owner = .{} };
    child._owner.set(Example.selfObject(Owner, owner));
    return child;
}

/// Child class with a PUBLIC Ref field (no underscore) — tests property exclusion
const RefChildPublic = struct {
    owner_ref: pyoz.Ref(Owner),
    tag: i64,

    pub fn has_owner(self: *const RefChildPublic) bool {
        return self.owner_ref.object() != null;
    }

    pub fn __repr__(self: *const RefChildPublic) []const u8 {
        _ = self;
        return "RefChildPublic(...)";
    }
};

// ============================================================================
// Test: raiseRuntimeError without inline (user bug report)
// ============================================================================

/// Test that raiseRuntimeError works without inline (one-liner pattern)
fn test_raise_runtime(value: i64) ?i64 {
    if (value < 0) return pyoz.raiseRuntimeError("value must be non-negative");
    return value * 2;
}

/// Test the two-line discard pattern: _ = pyoz.raiseValueError(...)
fn test_raise_discard(value: i64) ?i64 {
    if (value < 0) {
        _ = pyoz.raiseValueError("value must be non-negative");
        return null;
    }
    return value * 2;
}

// ============================================================================
// Test: pyoz.fmt() for formatted error messages
// ============================================================================

/// Test pyoz.fmt with raiseValueError
fn test_fmt_raise(value: i64, limit: i64) ?i64 {
    if (value > limit) return pyoz.raiseValueError(pyoz.fmt("value {d} exceeds limit {d}", .{ value, limit }));
    return value;
}

// Module Definition
// ============================================================================

/// Post-init callback: add submodules to the module
fn setupSubmodules(module: *pyoz.PyObject) callconv(.c) c_int {
    const mod = pyoz.Module{ .ptr = module };
    _ = mod.createSubmodule("math", "Mathematical utility functions", &math_methods) catch return -1;
    return 0;
}

pub const Example = pyoz.module(.{
    .name = "example",
    .doc = "Example PyOZ module - Python bindings for Zig made easy!",
    .module_init = &setupSubmodules,
    .funcs = &.{
        pyoz.func("add", add, "Add two integers"),
        pyoz.func("multiply", multiply, "Multiply two floats"),
        pyoz.func("divide", divide, "Divide two numbers (raises error if b=0)"),
        pyoz.func("validate_positive", validate_positive, "Validate that a number is non-negative"),
        pyoz.func("validate_positive_sig", validate_positive_sig, "Validate positive (Signature override)"),
        pyoz.func("safe_divide", safe_divide, "Divide with custom exception on zero"),
        pyoz.kwfunc("greet_person", greet_person, "Greet a person with keyword arguments"),
        pyoz.kwfunc("power", power, "Calculate base^exponent (default exponent=2)"),
        pyoz.func("compute_sum_no_gil", compute_sum_no_gil, "Sum of squares (releases GIL)"),
        pyoz.func("compute_sum_with_gil", compute_sum_with_gil, "Sum of squares (keeps GIL)"),
        pyoz.func("interruptible_sum", interruptible_sum, "Sum 0..n with Ctrl+C support"),
        pyoz.func("sum_dict_values", sum_dict_values, "Sum integer values in a dict"),
        pyoz.func("get_dict_value", get_dict_value, "Get value from dict by key"),
        pyoz.func("make_dict", make_dict, "Return a dict with one/two/three"),
        pyoz.func("dict_len", dict_len, "Get length of a dict"),
        pyoz.func("dict_has_key", dict_has_key, "Check if key exists in dict"),
        // List functions
        pyoz.func("sum_list", sum_list, "Sum integers in a list"),
        pyoz.func("list_get", list_get, "Get element at index from list"),
        pyoz.func("list_len", list_len, "Get length of a list"),
        pyoz.func("list_average", list_average, "Calculate average of floats"),
        pyoz.func("list_max", list_max, "Find max value in list"),
        pyoz.func("list_contains", list_contains, "Check if list contains value"),
        pyoz.func("join_strings", join_strings, "Join list of strings with separator"),
        // Set functions
        pyoz.func("sum_set", sum_set, "Sum integers in a set"),
        pyoz.func("set_len", set_len, "Get length of a set"),
        pyoz.func("set_has", set_has, "Check if set contains value"),
        pyoz.func("make_set", make_set, "Return a set of integers"),
        pyoz.func("make_frozenset", make_frozenset, "Return a frozen set of strings"),
        // Iterator functions - work with ANY iterable (list, tuple, set, generator, etc.)
        pyoz.func("iter_sum", iter_sum, "Sum integers from any iterable"),
        pyoz.func("iter_count", iter_count, "Count items in any iterable"),
        pyoz.func("iter_max", iter_max, "Find max value in any iterable"),
        pyoz.func("iter_min", iter_min, "Find min value in any iterable"),
        pyoz.func("iter_product", iter_product, "Calculate product of integers in any iterable"),
        pyoz.func("iter_join", iter_join, "Join strings from any iterable"),
        pyoz.func("iter_average", iter_average, "Calculate average of floats from any iterable"),
        // Iterator producer functions - return iterators to Python
        pyoz.func("get_fibonacci", get_fibonacci, "Return first 10 fibonacci numbers (eager, as list)"),
        pyoz.func("get_squares", get_squares, "Return squares of 1-5 (eager, as list)"),
        pyoz.func("lazy_range", lazy_range, "Return a lazy range iterator (like Python's range)"),
        pyoz.func("lazy_count", lazy_count, "Return a lazy counter from 0 to n-1"),
        pyoz.func("lazy_fibonacci", lazy_fibonacci, "Return a lazy fibonacci generator"),
        // DateTime functions
        pyoz.func("datetime_parts", datetime_parts, "Get datetime components as tuple"),
        pyoz.func("date_parts", date_parts, "Get date components as tuple"),
        pyoz.func("time_parts", time_parts, "Get time components as tuple"),
        pyoz.func("timedelta_parts", timedelta_parts, "Get timedelta components as tuple"),
        pyoz.func("make_datetime", make_datetime, "Create a datetime"),
        pyoz.func("make_date", make_date, "Create a date"),
        pyoz.func("make_time", make_time, "Create a time"),
        pyoz.func("make_timedelta", make_timedelta, "Create a timedelta"),
        pyoz.func("add_days_to_date", add_days_to_date, "Add days to a date"),
        // Bytes functions
        pyoz.func("bytes_len", bytes_len, "Get length of bytes"),
        pyoz.func("bytes_sum", bytes_sum, "Sum all bytes"),
        pyoz.func("make_bytes", make_bytes, "Create bytes"),
        pyoz.func("bytes_starts_with", bytes_starts_with, "Check if bytes starts with value"),
        // Path functions
        pyoz.func("path_str", path_str, "Get path as string"),
        pyoz.func("path_len", path_len, "Get length of path"),
        pyoz.func("make_path", make_path, "Create a path"),
        pyoz.func("path_starts_with", path_starts_with, "Check if path starts with prefix"),
        // Decimal functions
        pyoz.func("decimal_str", decimal_str, "Get decimal as string"),
        pyoz.func("make_decimal", make_decimal, "Create a decimal"),
        pyoz.func("decimal_double", decimal_double, "Double a decimal value"),
        // BigInt functions
        pyoz.func("bigint_echo", bigint_echo, "Echo an i128"),
        pyoz.func("biguint_echo", biguint_echo, "Echo a u128"),
        pyoz.func("bigint_max", bigint_max, "Return i128 max value"),
        pyoz.func("biguint_large", biguint_large, "Return u128 max value"),
        pyoz.func("bigint_add", bigint_add, "Add two i128 values"),
        // Complex number functions
        pyoz.func("complex_echo", complex_echo, "Echo a complex number"),
        pyoz.func("make_complex", make_complex, "Create a complex number"),
        pyoz.func("complex_magnitude", complex_magnitude, "Get magnitude of complex number"),
        pyoz.func("complex_add", complex_add, "Add two complex numbers"),
        pyoz.func("complex_mul", complex_mul, "Multiply two complex numbers"),
        // Callable wrapper functions
        pyoz.func("apply_callback", apply_callback, "Apply a callback to two args"),
        pyoz.func("transform_value", transform_value, "Transform a float with a callback"),
        pyoz.func("call_no_args", call_no_args, "Call a callback with no args"),
        pyoz.func("call_void", call_void, "Call a void callback"),
        // Exception catching functions
        pyoz.func("call_and_catch", call_and_catch, "Call a callable and catch exceptions"),
        pyoz.func("raise_value_error", raise_value_error, "Raise a ValueError with a message"),
        pyoz.func("check_exception_type", check_exception_type, "Check the type of exception a callable raises"),
        pyoz.func("parse_and_validate", parse_and_validate, "Parse and validate a value (demonstrates error mapping)"),
        pyoz.func("lookup_index", lookup_index, "Lookup by index (demonstrates IndexError mapping)"),
        pyoz.kwfunc("greet_named", greet_named, "Greet with named kwargs (name, greeting='Hello', times=1, excited=False)"),
        pyoz.kwfunc("calculate_named", calculate_named, "Calculate with named kwargs (x, y, operation='add')"),
        pyoz.func("greet", greet, "Greet someone"),
        pyoz.func("is_even", is_even, "Check if a number is even"),
        pyoz.func("answer", answer, "Get the answer to everything"),
        pyoz.func("distance", distance, "Calculate distance between two Points"),
        pyoz.func("midpoint_coords", midpoint_coords, "Get midpoint coordinates as tuple"),
        pyoz.func("get_range", get_range, "Get a list of integers from 0 to n-1"),
        pyoz.func("get_fibonacci_ratios", get_fibonacci_ratios, "Get fibonacci ratios as list"),
        pyoz.func("sum_triple", sum_triple, "Sum a list of exactly 3 integers"),
        pyoz.func("dot_product_3d", dot_product_3d, "Dot product of two 3D vectors"),
        // Numpy / BufferView functions (zero-copy array operations)
        pyoz.func("numpy_sum", numpy_sum, "Sum all elements in a numpy array (zero-copy)"),
        pyoz.func("numpy_get_2d", numpy_get_2d, "Get element at 2D index (tests dimension mismatch handling)"),
        pyoz.func("buffer_get_2d_i64", buffer_get_2d_i64, "Get element at 2D index for i64 arrays"),
        pyoz.func("numpy_mean", numpy_mean, "Calculate mean of a numpy array"),
        pyoz.func("numpy_minmax", numpy_minmax, "Find min and max of a numpy array"),
        pyoz.func("numpy_dot", numpy_dot, "Compute dot product of two numpy arrays"),
        pyoz.func("numpy_scale", numpy_scale, "Scale all elements in-place (mutable)"),
        pyoz.func("numpy_add_scalar", numpy_add_scalar, "Add a scalar to all elements in-place"),
        pyoz.func("numpy_fill", numpy_fill, "Fill array with a value in-place"),
        pyoz.func("numpy_normalize", numpy_normalize, "Normalize array in-place"),
        pyoz.func("numpy_multiply_inplace", numpy_multiply_inplace, "Element-wise multiply two arrays in-place"),
        pyoz.func("numpy_sum_int", numpy_sum_int, "Sum integers in an int64 numpy array"),
        pyoz.func("numpy_shape_info", numpy_shape_info, "Get array shape info as tuple"),
        pyoz.func("numpy_relu", numpy_relu, "Apply ReLU (max(0, x)) in-place"),
        pyoz.func("numpy_softmax", numpy_softmax, "Apply softmax normalization in-place"),
        pyoz.func("numpy_variance", numpy_variance, "Compute variance of array"),
        pyoz.func("numpy_std", numpy_std, "Compute standard deviation"),
        pyoz.func("numpy_clamp", numpy_clamp, "Clamp all values to [min, max] in-place"),
        // Complex number array functions
        pyoz.func("numpy_complex_sum", numpy_complex_sum, "Sum complex128 array elements"),
        pyoz.func("numpy_complex_magnitudes", numpy_complex_magnitudes, "Calculate magnitudes of complex array"),
        pyoz.func("numpy_complex_conjugate", numpy_complex_conjugate, "Conjugate all elements in-place"),
        pyoz.func("numpy_complex_scale", numpy_complex_scale, "Scale complex array by real factor"),
        pyoz.func("numpy_complex_dot", numpy_complex_dot, "Hermitian dot product of two complex arrays"),
        pyoz.func("numpy_complex64_sum", numpy_complex64_sum, "Sum complex64 array elements"),
        // Test: raise* functions without inline (user bug report)
        pyoz.func("test_raise_runtime", test_raise_runtime, "Test raiseRuntimeError one-liner pattern"),
        pyoz.func("test_raise_discard", test_raise_discard, "Test raiseValueError discard pattern"),
        pyoz.func("test_fmt_raise", test_fmt_raise, "Test pyoz.fmt with raiseValueError"),
        // Ref(T) test functions
        pyoz.func("make_ref_child", make_ref_child, "Create a RefChild holding a Ref to an Owner"),
        pyoz.func("make_ref_child_freelist", make_ref_child_freelist, "Create a RefChildFreelist holding a Ref to an Owner"),
    },
    .classes = &.{
        pyoz.class("Point", Point),
        pyoz.class("BoundedValue", BoundedValue),
        pyoz.class("IntArray", IntArray),
        pyoz.class("VulnArray", VulnArray),
        pyoz.class("BadBuffer", BadBuffer),
        pyoz.class("BadStrideBuffer", BadStrideBuffer),
        pyoz.class("Version", Version),
        pyoz.class("Number", Number),
        pyoz.class("Timer", Timer),
        pyoz.class("BitSet", BitSet),
        pyoz.class("PowerNumber", PowerNumber),
        pyoz.class("Adder", Adder),
        pyoz.class("Multiplier", Multiplier),
        pyoz.class("TypedAttribute", TypedAttribute),
        pyoz.class("Vector", Vector),
        pyoz.class("DynamicObject", DynamicObject),
        pyoz.class("ReversibleList", ReversibleList),
        pyoz.class("FrozenPoint", FrozenPoint),
        pyoz.class("Circle", Circle),
        pyoz.class("Stack", Stack),
        pyoz.class("DefaultDict", DefaultDict),
        pyoz.class("Container", Container),
        pyoz.class("Flexible", Flexible),
        pyoz.class("Temperature", Temperature),
        pyoz.class("PrivateFieldsExample", PrivateFieldsExample),
        pyoz.class("ArenaClass", ArenaClass),
        pyoz.class("SimplePoint", SimplePoint),
        pyoz.class("Resource", Resource),
        pyoz.class("FailingResource", FailingResource),
        pyoz.class("FlexPoint", FlexPoint),
        pyoz.class("Line", Line),
        pyoz.class("Owner", Owner),
        pyoz.class("RefChild", RefChild),
        pyoz.class("RefChildFreelist", RefChildFreelist),
        pyoz.class("RefChildPublic", RefChildPublic),
        pyoz.class("ValidatedProp", ValidatedProp),
    },
    .exceptions = &.{
        pyoz.exception("ValidationError", .{ .doc = "Raised when validation fails", .base = .ValueError }),
        pyoz.exception("MathError", .{ .doc = "Raised for math errors like division by zero", .base = .RuntimeError }),
        pyoz.exception("MyTypeError", .TypeError), // shorthand syntax
        pyoz.exception("MyIndexError", .IndexError), // shorthand syntax
    },
    .error_mappings = &.{
        pyoz.mapError("NegativeValue", .ValueError),
        pyoz.mapErrorMsg("ValueTooLarge", .ValueError, "Value exceeds maximum of 1000"),
        pyoz.mapErrorMsg("ForbiddenValue", .ValueError, "The value 42 is forbidden"),
        pyoz.mapError("IndexOutOfBounds", .IndexError),
        pyoz.mapError("DivisionByZero", .RuntimeError),
    },
    .enums = &.{
        pyoz.enumDef("Color", Color), // auto-detected as IntEnum (enum(i32))
        pyoz.enumDef("HttpStatus", HttpStatus), // auto-detected as IntEnum (enum(i32))
        pyoz.enumDef("TaskStatus", TaskStatus), // auto-detected as StrEnum (plain enum)
        pyoz.enumDef("LogLevel", LogLevel), // auto-detected as StrEnum (plain enum)
    },
    .consts = &.{
        pyoz.constant("VERSION", "1.0.0"),
        pyoz.constant("PI", 3.14159265358979),
        pyoz.constant("MAX_VALUE", @as(i64, 1000000)),
        pyoz.constant("DEBUG", false),
    },
    // .from: auto-scan a Zig namespace — all pub fns, constants, and
    // docstrings are discovered automatically with zero registration boilerplate.
    // withSource enables automatic /// doc comments and parameter name extraction.
    .from = &.{
        pyoz.withSource(@import("from_extras.zig"), @embedFile("from_extras.zig")),
    },
});

// ============================================================================
// Submodule: example.math - Mathematical utilities
// ============================================================================

/// Compute factorial
fn math_factorial(n: i64) !i64 {
    if (n < 0) return error.NegativeValue;
    if (n > 20) return error.ValueTooLarge; // Prevent overflow
    var result: i64 = 1;
    var i: i64 = 2;
    while (i <= n) : (i += 1) {
        result *= i;
    }
    return result;
}

/// Compute GCD of two numbers
fn math_gcd(a: i64, b: i64) i64 {
    var x = if (a < 0) -a else a;
    var y = if (b < 0) -b else b;
    while (y != 0) {
        const temp = y;
        y = @mod(x, y);
        x = temp;
    }
    return x;
}

/// Compute LCM of two numbers
fn math_lcm(a: i64, b: i64) i64 {
    if (a == 0 or b == 0) return 0;
    const gcd_val = math_gcd(a, b);
    return @divExact(if (a < 0) -a else a, gcd_val) * (if (b < 0) -b else b);
}

/// Check if a number is prime
fn math_is_prime(n: i64) bool {
    if (n < 2) return false;
    if (n == 2) return true;
    if (@mod(n, 2) == 0) return false;
    var i: i64 = 3;
    while (i * i <= n) : (i += 2) {
        if (@mod(n, i) == 0) return false;
    }
    return true;
}

/// Submodule method definitions
var math_methods = [_]pyoz.PyMethodDef{
    pyoz.methodDef("factorial", &pyoz.wrapFunc(math_factorial), "Compute factorial of n"),
    pyoz.methodDef("gcd", &pyoz.wrapFunc(math_gcd), "Compute GCD of two numbers"),
    pyoz.methodDef("lcm", &pyoz.wrapFunc(math_lcm), "Compute LCM of two numbers"),
    pyoz.methodDef("is_prime", &pyoz.wrapFunc(math_is_prime), "Check if a number is prime"),
    pyoz.methodDefSentinel(),
};

// Required: forces analysis of all pub decls so PyInit_ is exported.
comptime {
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        _ = @field(@This(), decl.name);
    }
}
