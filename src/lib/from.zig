//! `.from` Auto-Scan Infrastructure for PyOZ
//!
//! Provides comptime helpers for auto-scanning Zig namespaces and registering
//! their public declarations (functions, classes, enums, constants, exceptions)
//! as Python module members. This dramatically reduces boilerplate when the
//! Python name matches the Zig identifier.
//!
//! See NEW_API.md for the full specification.

const std = @import("std");
const root = @import("root.zig");
const py = root.py;
const PyObject = py.PyObject;
const ExcBase = root.ExcBase;
const ErrorMapping = root.ErrorMapping;
const source_parser = @import("source_parser.zig");

// =============================================================================
// Source Options
// =============================================================================

/// Filtering options for `source()`. Allows restricting which declarations
/// from a namespace are exported.
pub const SourceOptions = struct {
    /// If non-null, only export declarations with these names.
    only: ?[]const []const u8 = null,
    /// If non-null, exclude declarations with these names.
    exclude: ?[]const []const u8 = null,
};

// =============================================================================
// Marker Type Constructors
// =============================================================================

/// Filter a namespace, exporting only selected declarations.
///
/// Usage:
///   .from = &.{ pyoz.source(math_funcs, .{ .only = &.{"add", "sub"} }) }
pub fn source(comptime namespace: type, comptime options: SourceOptions) type {
    @setEvalBranchQuota(std.math.maxInt(u32));
    // Validate mutual exclusivity
    if (options.only != null and options.exclude != null) {
        @compileError("pyoz.source(): .only and .exclude are mutually exclusive. Use one or the other.");
    }

    // Validate that filter names actually exist in the namespace
    if (options.only) |only_list| {
        const decls = @typeInfo(namespace).@"struct".decls;
        for (only_list) |name| {
            var found = false;
            for (decls) |d| {
                if (std.mem.eql(u8, d.name, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                @compileLog("PyOZ .from: source() .only name '" ++ name ++ "' does not match any pub declaration (possible typo)");
            }
        }
    }
    if (options.exclude) |exclude_list| {
        const decls = @typeInfo(namespace).@"struct".decls;
        for (exclude_list) |name| {
            var found = false;
            for (decls) |d| {
                if (std.mem.eql(u8, d.name, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                @compileLog("PyOZ .from: source() .exclude name '" ++ name ++ "' does not match any pub declaration (possible typo)");
            }
        }
    }

    return struct {
        pub const _is_pyoz_source = true;
        pub const _source_namespace = namespace;
        pub const _source_options = options;
    };
}

/// Attach source text to a namespace for automatic docstring and parameter extraction.
/// The `@import` and `@embedFile` are both called at the user's call site,
/// so file paths resolve correctly without any boilerplate in the `.from` file.
///
/// Usage:
///   .from = &.{ pyoz.withSource(@import("funcs.zig"), @embedFile("funcs.zig")) }
pub fn withSource(comptime namespace: type, comptime src: [:0]const u8) type {
    return struct {
        pub const _is_pyoz_with_source = true;
        pub const _ws_namespace = namespace;
        pub const _ws_source: [:0]const u8 = src;
        pub const _ws_parsed: source_parser.ParsedSource = source_parser.parse(src);
    };
}

/// Declare a submodule from a namespace.
///
/// Usage:
///   .from = &.{ pyoz.sub("utils", utils) }
pub fn sub(comptime name: [*:0]const u8, comptime ns_or_source: type) type {
    return struct {
        pub const _is_pyoz_sub = true;
        pub const _sub_name: [*:0]const u8 = name;
        pub const _sub_inner = ns_or_source;
    };
}

/// Declare a custom exception for `.from` scanning.
///
/// Usage (in a namespace scanned by .from):
///   pub const MyError = pyoz.Exception(.ValueError, "Something went wrong");
pub fn Exception(comptime base_exc: ExcBase, comptime doc: ?[*:0]const u8) type {
    return struct {
        pub const _is_pyoz_from_exception = true;
        pub const _exc_base: ExcBase = base_exc;
        pub const _exc_doc: ?[*:0]const u8 = doc;
    };
}

/// Declare error-to-exception mappings for `.from` scanning.
///
/// Usage (in a namespace scanned by .from):
///   pub const __errors__ = pyoz.ErrorMap(.{
///       .{ "OutOfMemory", .MemoryError },
///       .{ "DivisionByZero", .ZeroDivisionError },
///   });
pub fn ErrorMapType(comptime mappings: anytype) type {
    return struct {
        pub const _is_pyoz_error_map = true;
        pub const _error_mappings = mappings;
    };
}

// =============================================================================
// Namespace Resolution Helpers
// =============================================================================

/// Check if a .from entry is a `source()` filtered namespace.
pub fn isSource(comptime entry: type) bool {
    return @hasDecl(entry, "_is_pyoz_source");
}

/// Check if a .from entry is a `sub()` submodule.
pub fn isSub(comptime entry: type) bool {
    return @hasDecl(entry, "_is_pyoz_sub");
}

/// Extract the actual namespace type from a .from entry.
/// Works for bare namespaces, source(), withSource(), and the inner part of sub().
pub fn resolveNamespace(comptime entry: type) type {
    // Use @hasDecl directly so Zig can prune branches for bare namespace types
    if (@hasDecl(entry, "_is_pyoz_with_source")) {
        return resolveNamespace(entry._ws_namespace);
    }
    if (@hasDecl(entry, "_is_pyoz_source")) {
        return resolveNamespace(entry._source_namespace);
    }
    if (@hasDecl(entry, "_is_pyoz_sub")) {
        return resolveNamespace(entry._sub_inner);
    }
    // Bare namespace — it IS the namespace
    return entry;
}

/// Get SourceOptions for a .from entry. Returns default (no filtering) for bare namespaces.
pub fn getSourceOptions(comptime entry: type) SourceOptions {
    // Use @hasDecl directly so Zig can prune branches for bare namespace types
    if (@hasDecl(entry, "_is_pyoz_source")) {
        return entry._source_options;
    }
    if (@hasDecl(entry, "_is_pyoz_sub")) {
        return getSourceOptions(entry._sub_inner);
    }
    return .{};
}

/// Get the submodule name from a sub() entry.
pub fn getSubName(comptime entry: type) [*:0]const u8 {
    return entry._sub_name;
}

// =============================================================================
// Name Helpers
// =============================================================================

/// Check if a declaration name should be skipped during scanning.
/// Skips: underscore-prefixed, __doc__ suffixed, __errors__, and PyOZ marker decls.
pub fn isSkippableName(comptime name: []const u8) bool {
    // Skip underscore-prefixed names
    if (name.len > 0 and name[0] == '_') return true;
    // Skip __errors__ (ErrorMap marker)
    if (std.mem.eql(u8, name, "__errors__")) return true;
    // Skip names ending with __doc__ (docstring declarations)
    if (isDocName(name) != null) return true;
    // Skip names ending with __params__ (parameter name overrides)
    if (name.len > 10 and std.mem.endsWith(u8, name, "__params__")) return true;
    return false;
}

/// Check if a name is a docstring declaration (e.g., "add__doc__" → "add").
/// Returns the base name if it's a docstring, null otherwise.
pub fn isDocName(comptime name: []const u8) ?[]const u8 {
    if (name.len > 7 and std.mem.endsWith(u8, name, "__doc__")) {
        return name[0 .. name.len - 7];
    }
    return null;
}

/// Convert a comptime []const u8 to [*:0]const u8.
pub fn comptimeStrZ(comptime s: []const u8) [*:0]const u8 {
    return (s ++ "\x00")[0..s.len :0].ptr;
}

/// Resolve source text from a `.from` entry by walking the wrapper chain.
/// Checks (in order): withSource() wrapper, source() inner, sub() inner,
/// then the bare namespace for `__source__` (function or constant form).
pub fn resolveSource(comptime entry: type) ?[:0]const u8 {
    // withSource() wrapper — has explicit source text
    if (@hasDecl(entry, "_is_pyoz_with_source")) {
        return entry._ws_source;
    }
    // source() wrapper — check inner
    if (@hasDecl(entry, "_is_pyoz_source")) {
        return resolveSource(entry._source_namespace);
    }
    // sub() wrapper — check inner
    if (@hasDecl(entry, "_is_pyoz_sub")) {
        return resolveSource(entry._sub_inner);
    }
    // Bare namespace — check for __source__ function or constant
    if (@hasDecl(entry, "__source__")) {
        const field = @field(entry, "__source__");
        const T = @TypeOf(field);
        const info = @typeInfo(T);
        // Function form: pub fn __source__() [:0]const u8
        if (info == .@"fn") return field();
        // Constant form: pub const __source__: [:0]const u8
        if (info == .pointer) return field;
    }
    return null;
}

/// Resolve pre-parsed source data from a `.from` entry.
/// For withSource() entries, returns the eagerly-parsed data (no re-tokenization).
/// For __source__ entries, parses on the fly (fallback path).
pub fn resolveParsedSource(comptime entry: type) ?source_parser.ParsedSource {
    // withSource() wrapper — has pre-parsed data
    if (@hasDecl(entry, "_is_pyoz_with_source")) {
        return entry._ws_parsed;
    }
    // source() wrapper — check inner
    if (@hasDecl(entry, "_is_pyoz_source")) {
        return resolveParsedSource(entry._source_namespace);
    }
    // sub() wrapper — check inner
    if (@hasDecl(entry, "_is_pyoz_sub")) {
        return resolveParsedSource(entry._sub_inner);
    }
    // Bare namespace — parse on the fly from __source__
    if (resolveSource(entry)) |src| {
        return comptime source_parser.parse(src);
    }
    return null;
}

/// Look up the docstring for a declaration in a `.from` entry.
/// Priority: 1. explicit `{name}__doc__`, 2. `///` from source parsing.
/// Accepts a `.from` entry type (bare namespace, source(), withSource(), or sub() wrapper).
pub fn getDocstring(comptime entry: type, comptime name: []const u8) ?[*:0]const u8 {
    const ns = resolveNamespace(entry);
    // 1. Try explicit name__doc__
    const doc_name = name ++ "__doc__";
    if (@hasDecl(ns, doc_name)) {
        const doc_val = @field(ns, doc_name);
        const DT = @TypeOf(doc_val);
        if (DT == [*:0]const u8) {
            return doc_val;
        }
        if (DT == []const u8) {
            return comptimeStrZ(doc_val);
        }
        // Handle *const [N:0]u8 (string literals)
        const dt_info = @typeInfo(DT);
        if (dt_info == .pointer and dt_info.pointer.size == .one) {
            const child = @typeInfo(dt_info.pointer.child);
            if (child == .array and child.array.child == u8 and child.array.sentinel_ptr != null) {
                return doc_val;
            }
        }
    }
    // 2. Try source parser (/// doc comment)
    if (resolveParsedSource(entry)) |parsed| {
        if (source_parser.getDoc(parsed, name)) |doc| {
            return comptimeStrZ(doc);
        }
    }
    return null;
}

/// Get the namespace-level docstring for use as module docstring.
/// Priority: 1. explicit `__doc__`, 2. `//!` from source parsing.
/// Accepts a `.from` entry type (bare namespace, source(), withSource(), or sub() wrapper).
pub fn getNamespaceDoc(comptime entry: type) ?[*:0]const u8 {
    const ns = resolveNamespace(entry);
    // 1. Try explicit __doc__
    if (@hasDecl(ns, "__doc__")) {
        const doc_val = @field(ns, "__doc__");
        const DT = @TypeOf(doc_val);
        if (DT == [*:0]const u8) {
            return doc_val;
        }
        if (DT == []const u8) {
            return comptimeStrZ(doc_val);
        }
        // Handle *const [N:0]u8 (string literals)
        const dt_info = @typeInfo(DT);
        if (dt_info == .pointer and dt_info.pointer.size == .one) {
            const child = @typeInfo(dt_info.pointer.child);
            if (child == .array and child.array.child == u8 and child.array.sentinel_ptr != null) {
                return doc_val;
            }
        }
    }
    // 2. Try source parser (//! module doc comment)
    if (resolveParsedSource(entry)) |parsed| {
        if (parsed.module_doc) |doc| {
            return comptimeStrZ(doc);
        }
    }
    return null;
}

/// Look up parameter names for a function in a `.from` entry.
/// Priority: 1. explicit `{name}__params__`, 2. parsed from source.
/// Returns comma-separated names (e.g., "a, b") or null.
/// Accepts a `.from` entry type (bare namespace, source(), withSource(), or sub() wrapper).
pub fn getParamNames(comptime entry: type, comptime name: []const u8) ?[]const u8 {
    const ns = resolveNamespace(entry);
    // 1. Try explicit name__params__
    const params_name = name ++ "__params__";
    if (@hasDecl(ns, params_name)) {
        const val = @field(ns, params_name);
        const PT = @TypeOf(val);
        if (PT == []const u8) return val;
        if (PT == [*:0]const u8) return std.mem.span(val);
        // Handle string literals
        const pt_info = @typeInfo(PT);
        if (pt_info == .pointer and pt_info.pointer.size == .one) {
            const child = @typeInfo(pt_info.pointer.child);
            if (child == .array and child.array.child == u8) {
                return std.mem.span(@as([*:0]const u8, val));
            }
        }
    }
    // 2. Try source parser
    if (resolveParsedSource(entry)) |parsed| {
        return source_parser.getParamNames(parsed, name);
    }
    return null;
}

/// Look up a class doc comment from the source of a `.from` entry.
/// This is for `.from` classes where the `///` doc is above `pub const Struct = struct`.
/// Returns null if no source or no doc found.
/// Accepts a `.from` entry type (bare namespace, source(), withSource(), or sub() wrapper).
pub fn getClassDoc(comptime entry: type, comptime struct_name: []const u8) ?[*:0]const u8 {
    if (resolveParsedSource(entry)) |parsed| {
        if (source_parser.getDoc(parsed, struct_name)) |doc| {
            return comptimeStrZ(doc);
        }
    }
    return null;
}

/// Check if a namespace has __tests__ (inline test definitions).
pub fn hasTests(comptime ns: type) bool {
    return @hasDecl(ns, "__tests__");
}

/// Check if a namespace has __benchmarks__ (inline benchmark definitions).
pub fn hasBenchmarks(comptime ns: type) bool {
    return @hasDecl(ns, "__benchmarks__");
}

// =============================================================================
// Type Classification
// =============================================================================

/// Check if a type is a `.from` exception marker.
pub fn isFromException(comptime T: type) bool {
    return @typeInfo(T) == .type and @hasDecl(@as(type, T), "_is_pyoz_from_exception");
}

/// Check if a type is a `.from` error map marker.
pub fn isFromErrorMap(comptime T: type) bool {
    return @typeInfo(T) == .type and @hasDecl(@as(type, T), "_is_pyoz_error_map");
}

/// Check if a struct type looks like a class (has fields, methods, __new__, __doc__, etc.)
pub fn isClassLikeStruct(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    // Tuples are not classes
    if (info.@"struct".is_tuple) return false;
    // Types with PyOZ markers are not classes (they're special types)
    if (@hasDecl(T, "_is_pyoz_complex") or
        @hasDecl(T, "_is_pyoz_datetime") or
        @hasDecl(T, "_is_pyoz_date") or
        @hasDecl(T, "_is_pyoz_time") or
        @hasDecl(T, "_is_pyoz_timedelta") or
        @hasDecl(T, "_is_pyoz_bytes") or
        @hasDecl(T, "_is_pyoz_bytearray") or
        @hasDecl(T, "_is_pyoz_path") or
        @hasDecl(T, "_is_pyoz_decimal") or
        @hasDecl(T, "_is_pyoz_owned") or
        @hasDecl(T, "_is_pyoz_dict") or
        @hasDecl(T, "_is_pyoz_iterator") or
        @hasDecl(T, "_is_pyoz_lazy_iterator") or
        @hasDecl(T, "_is_pyoz_set") or
        @hasDecl(T, "_is_pyoz_frozenset") or
        @hasDecl(T, "_is_pyoz_dict_view") or
        @hasDecl(T, "_is_pyoz_list_view") or
        @hasDecl(T, "_is_pyoz_set_view") or
        @hasDecl(T, "_is_pyoz_iterator_view") or
        @hasDecl(T, "_is_pyoz_callable") or
        @hasDecl(T, "_is_pyoz_buffer") or
        @hasDecl(T, "_is_pyoz_buffer_mut") or
        @hasDecl(T, "_is_pyoz_signature") or
        @hasDecl(T, "_is_pyoz_source") or
        @hasDecl(T, "_is_pyoz_sub") or
        @hasDecl(T, "_is_pyoz_from_exception") or
        @hasDecl(T, "_is_pyoz_error_map") or
        @hasDecl(T, "_is_pyoz_base") or
        @hasDecl(T, "is_pyoz_args") or
        @hasDecl(T, "__pyoz_property__")) return false;

    const fields = info.@"struct".fields;
    // Must have at least one data field to be a class
    if (fields.len == 0) return false;
    return true;
}

/// Check if a type is an enum that should be exported.
pub fn isEnumType(comptime T: type) bool {
    return @typeInfo(T) == .@"enum";
}

/// Check if a value type is a scalar constant (int, float, bool, comptime_int, comptime_float).
pub fn isScalarConstType(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .int or info == .float or info == .bool or
        info == .comptime_int or info == .comptime_float;
}

/// Check if a value type is a string constant.
pub fn isStringConstType(comptime T: type) bool {
    const info = @typeInfo(T);
    // []const u8
    if (info == .pointer and info.pointer.size == .slice and info.pointer.child == u8) return true;
    // [*:0]const u8
    if (info == .pointer and info.pointer.size == .many and info.pointer.child == u8 and
        info.pointer.sentinel_ptr != null) return true;
    // *const [N:0]u8 (string literal pointer)
    if (info == .pointer and info.pointer.size == .one) {
        const child = @typeInfo(info.pointer.child);
        if (child == .array and child.array.child == u8 and child.array.sentinel_ptr != null) return true;
    }
    return false;
}

// =============================================================================
// Calling Convention Detection
// =============================================================================

/// Check if a function takes pyoz.Args(T) as its last parameter.
/// This means it uses named keyword arguments.
/// Works for both module functions `fn(Args(T))` and methods `fn(*Self, Args(T))`.
pub fn isNamedKwargsFunc(comptime Fn: type) bool {
    const info = @typeInfo(Fn);
    if (info != .@"fn") return false;

    const params = info.@"fn".params;
    if (params.len == 0) return false;

    const ParamType = params[params.len - 1].type orelse return false;
    if (@typeInfo(ParamType) != .@"struct") return false;

    return @hasDecl(ParamType, "is_pyoz_args");
}

/// Check if a function has any optional (?T) parameters.
/// Used by .from auto-scan to auto-detect kwargs-capable functions.
/// Functions with optional params can accept those params as keyword arguments
/// without requiring the pyoz.Args(T) wrapper.
pub fn hasOptionalParams(comptime Fn: type) bool {
    const info = @typeInfo(Fn);
    if (info != .@"fn") return false;
    for (info.@"fn".params) |param| {
        const ptype = param.type orelse continue;
        if (@typeInfo(ptype) == .optional) return true;
    }
    return false;
}

// =============================================================================
// Filtering
// =============================================================================

/// Check if a name passes the source filter options.
fn passesFilter(comptime name: []const u8, comptime opts: SourceOptions) bool {
    if (opts.only) |only_list| {
        var found = false;
        for (only_list) |allowed| {
            if (std.mem.eql(u8, name, allowed)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    if (opts.exclude) |exclude_list| {
        for (exclude_list) |excluded| {
            if (std.mem.eql(u8, name, excluded)) return false;
        }
    }
    return true;
}

/// Check if a name is in the explicit name set (should be skipped in .from).
fn isInExplicitNames(comptime name: []const u8, comptime explicit_names: []const []const u8) bool {
    for (explicit_names) |en| {
        if (std.mem.eql(u8, name, en)) return true;
    }
    return false;
}

// =============================================================================
// Declaration Classification (should export as X?)
// =============================================================================

/// Check if a declaration should be exported as a module-level function.
pub fn shouldExportAsFunction(
    comptime ns: type,
    comptime name: []const u8,
    comptime opts: SourceOptions,
    comptime explicit_names: []const []const u8,
) bool {
    if (isSkippableName(name)) return false;
    if (!passesFilter(name, opts)) return false;
    if (isInExplicitNames(name, explicit_names)) return false;

    const field_type = @TypeOf(@field(ns, name));
    // Must be a function
    if (@typeInfo(field_type) != .@"fn") return false;

    // Check for incompatible signatures (comptime/generic params, type params)
    const fn_info = @typeInfo(field_type).@"fn";
    for (fn_info.params) |param| {
        // Generic/inferred param (type is null) → not Python-compatible
        if (param.type == null) return false;
        // `type` param → comptime-only, not callable from Python
        if (param.type.? == type) return false;
    }

    return true;
}

/// Check if a declaration should be exported as a class.
pub fn shouldExportAsClass(
    comptime ns: type,
    comptime name: []const u8,
    comptime opts: SourceOptions,
    comptime explicit_names: []const []const u8,
) bool {
    if (isSkippableName(name)) return false;
    if (!passesFilter(name, opts)) return false;
    if (isInExplicitNames(name, explicit_names)) return false;

    const field_type = @TypeOf(@field(ns, name));
    if (field_type != type) return false;
    const T = @field(ns, name);
    return isClassLikeStruct(T);
}

/// Check if a declaration should be exported as an enum.
pub fn shouldExportAsEnum(
    comptime ns: type,
    comptime name: []const u8,
    comptime opts: SourceOptions,
    comptime explicit_names: []const []const u8,
) bool {
    if (isSkippableName(name)) return false;
    if (!passesFilter(name, opts)) return false;
    if (isInExplicitNames(name, explicit_names)) return false;

    const field_type = @TypeOf(@field(ns, name));
    if (field_type != type) return false;
    const T = @field(ns, name);
    return isEnumType(T);
}

/// Check if a declaration should be exported as an exception.
pub fn shouldExportAsException(
    comptime ns: type,
    comptime name: []const u8,
    comptime opts: SourceOptions,
    comptime explicit_names: []const []const u8,
) bool {
    if (isSkippableName(name)) return false;
    if (!passesFilter(name, opts)) return false;
    if (isInExplicitNames(name, explicit_names)) return false;

    const field_type = @TypeOf(@field(ns, name));
    if (field_type != type) return false;
    const T = @field(ns, name);
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "_is_pyoz_from_exception");
}

/// Check if a declaration should be exported as a constant (scalar or string).
pub fn shouldExportAsConstant(
    comptime ns: type,
    comptime name: []const u8,
    comptime opts: SourceOptions,
    comptime explicit_names: []const []const u8,
) bool {
    if (isSkippableName(name)) return false;
    if (!passesFilter(name, opts)) return false;
    if (isInExplicitNames(name, explicit_names)) return false;

    const field_type = @TypeOf(@field(ns, name));

    // Skip type values — those are classes, enums, exceptions, etc.
    if (field_type == type) return false;
    // Skip functions
    if (@typeInfo(field_type) == .@"fn") return false;

    return isScalarConstType(field_type) or isStringConstType(field_type);
}

/// Check if a declaration is an __errors__ ErrorMap.
pub fn isErrorMapDecl(comptime ns: type, comptime name: []const u8) bool {
    if (!std.mem.eql(u8, name, "__errors__")) return false;
    const field_type = @TypeOf(@field(ns, name));
    if (field_type != type) return false;
    const T = @field(ns, name);
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "_is_pyoz_error_map");
}

// =============================================================================
// Counting Functions (for array sizing)
// =============================================================================

/// Count how many functions all .from entries contribute.
pub fn countAllFromFunctions(
    comptime from_entries: anytype,
    comptime explicit_names: []const []const u8,
) usize {
    var count: usize = 0;
    for (from_entries) |entry| {
        if (isSub(entry)) continue;
        const ns = resolveNamespace(entry);
        const opts = getSourceOptions(entry);
        const decls = @typeInfo(ns).@"struct".decls;
        for (decls) |d| {
            if (shouldExportAsFunction(ns, d.name, opts, explicit_names)) {
                count += 1;
            }
        }
    }
    return count;
}

/// Count how many classes all .from entries contribute.
pub fn countAllFromClasses(
    comptime from_entries: anytype,
    comptime explicit_names: []const []const u8,
) usize {
    var count: usize = 0;
    for (from_entries) |entry| {
        if (isSub(entry)) continue;
        const ns = resolveNamespace(entry);
        const opts = getSourceOptions(entry);
        const decls = @typeInfo(ns).@"struct".decls;
        for (decls) |d| {
            if (shouldExportAsClass(ns, d.name, opts, explicit_names)) {
                count += 1;
            }
        }
    }
    return count;
}

/// Count how many enums all .from entries contribute.
pub fn countAllFromEnums(
    comptime from_entries: anytype,
    comptime explicit_names: []const []const u8,
) usize {
    var count: usize = 0;
    for (from_entries) |entry| {
        if (isSub(entry)) continue;
        const ns = resolveNamespace(entry);
        const opts = getSourceOptions(entry);
        const decls = @typeInfo(ns).@"struct".decls;
        for (decls) |d| {
            if (shouldExportAsEnum(ns, d.name, opts, explicit_names)) {
                count += 1;
            }
        }
    }
    return count;
}

/// Count how many constants all .from entries contribute.
pub fn countAllFromConstants(
    comptime from_entries: anytype,
    comptime explicit_names: []const []const u8,
) usize {
    var count: usize = 0;
    for (from_entries) |entry| {
        if (isSub(entry)) continue;
        const ns = resolveNamespace(entry);
        const opts = getSourceOptions(entry);
        const decls = @typeInfo(ns).@"struct".decls;
        for (decls) |d| {
            if (shouldExportAsConstant(ns, d.name, opts, explicit_names)) {
                count += 1;
            }
        }
    }
    return count;
}

/// Count how many exceptions all .from entries contribute.
pub fn countAllFromExceptions(
    comptime from_entries: anytype,
    comptime explicit_names: []const []const u8,
) usize {
    var count: usize = 0;
    for (from_entries) |entry| {
        if (isSub(entry)) continue;
        const ns = resolveNamespace(entry);
        const opts = getSourceOptions(entry);
        const decls = @typeInfo(ns).@"struct".decls;
        for (decls) |d| {
            if (shouldExportAsException(ns, d.name, opts, explicit_names)) {
                count += 1;
            }
        }
    }
    return count;
}

/// Count error mappings from all .from entries.
pub fn countAllFromErrorMappings(comptime from_entries: anytype) usize {
    var count: usize = 0;
    for (from_entries) |entry| {
        if (isSub(entry)) continue;
        const ns = resolveNamespace(entry);
        const decls = @typeInfo(ns).@"struct".decls;
        for (decls) |d| {
            if (isErrorMapDecl(ns, d.name)) {
                const ErrMap = @field(ns, d.name);
                count += ErrMap._error_mappings.len;
            }
        }
    }
    return count;
}

// =============================================================================
// Duplicate Detection
// =============================================================================

/// Check for duplicate names across .from entries (from-to-from duplicates are errors).
pub fn checkFromDuplicates(comptime from_entries: anytype) void {
    // Collect all exported names from all .from entries
    comptime {
        // Use a simple O(n^2) scan for duplicates between different entries
        var all_names: [4096]struct { name: []const u8, source_idx: usize } = undefined;
        var name_count: usize = 0;

        for (from_entries, 0..) |entry, entry_idx| {
            if (isSub(entry)) continue;
            const ns = resolveNamespace(entry);
            const opts = getSourceOptions(entry);
            const decls = @typeInfo(ns).@"struct".decls;
            for (decls) |d| {
                if (isSkippableName(d.name)) continue;
                if (!passesFilter(d.name, opts)) continue;

                // Check for duplicate against previous entries
                for (all_names[0..name_count]) |prev| {
                    if (std.mem.eql(u8, prev.name, d.name) and prev.source_idx != entry_idx) {
                        @compileError(".from duplicate: \"" ++ d.name ++ "\" appears in multiple .from namespaces. " ++
                            "Use pyoz.source() with .only/.exclude to resolve the conflict.");
                    }
                }

                all_names[name_count] = .{ .name = d.name, .source_idx = entry_idx };
                name_count += 1;
            }
        }
    }
}

/// Build the explicit name set from all explicit config fields.
/// This is used to implement "explicit wins over .from" deduplication.
pub fn buildExplicitNameSet(comptime config: anytype) []const []const u8 {
    comptime {
        @setEvalBranchQuota(std.math.maxInt(u32));
        var names: [4096][]const u8 = undefined;
        var count: usize = 0;

        // Collect from explicit funcs
        if (@hasField(@TypeOf(config), "funcs")) {
            for (config.funcs) |f| {
                names[count] = std.mem.span(f.name);
                count += 1;
            }
        }

        // Collect from explicit classes
        if (@hasField(@TypeOf(config), "classes")) {
            for (config.classes) |cls| {
                names[count] = std.mem.span(cls.name);
                count += 1;
            }
        }

        // Collect from explicit enums
        if (@hasField(@TypeOf(config), "enums")) {
            for (config.enums) |e| {
                names[count] = std.mem.span(e.name);
                count += 1;
            }
        }

        // Collect from explicit str_enums (legacy)
        if (@hasField(@TypeOf(config), "str_enums")) {
            for (config.str_enums) |e| {
                names[count] = std.mem.span(e.name);
                count += 1;
            }
        }

        // Collect from explicit consts
        if (@hasField(@TypeOf(config), "consts")) {
            for (config.consts) |c| {
                names[count] = std.mem.span(c.name);
                count += 1;
            }
        }

        // Collect from explicit exceptions
        if (@hasField(@TypeOf(config), "exceptions")) {
            for (config.exceptions) |exc| {
                names[count] = std.mem.span(exc.name);
                count += 1;
            }
        }

        const final = names[0..count].*;
        return &final;
    }
}

// =============================================================================
// Enum Int/Str Detection (mirrors enums.zig logic)
// =============================================================================

/// Check if an enum has an explicit integer tag type (like u8, i32, etc.)
/// Must match the logic in enums.zig — check for standard integer types that
/// a user would explicitly specify (u8, u16, u32, u64, i8, i16, i32, i64, etc.).
/// Auto-generated tags use non-standard bit widths (u1, u2, u3, ...) that won't match.
pub fn isIntEnum(comptime E: type) bool {
    const tag_type = @typeInfo(E).@"enum".tag_type;
    return tag_type == i8 or tag_type == i16 or tag_type == i32 or tag_type == i64 or
        tag_type == u8 or tag_type == u16 or tag_type == u32 or tag_type == u64 or
        tag_type == isize or tag_type == c_int or tag_type == c_long;
}
