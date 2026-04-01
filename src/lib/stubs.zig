//! Stub Generation Module for PyOZ
//!
//! Generates Python type stub (.pyi) files at comptime from module definitions.
//! This provides IDE autocomplete, type checking with mypy/pyright, and visible
//! function signatures.
//!
//! Private fields: Fields starting with underscore (_) are considered private
//! and are NOT included in generated stubs (neither as annotations nor __init__ args).
//!
//! User-facing conventions for stub customization (all opt-in):
//! - `pub const method__doc__: [*:0]const u8 = "..."` — method docstring
//! - `pub const method__params__: []const u8 = "..."` — override parameter names (comma-separated)
//! - `pyoz.Signature(T, "python_type")` as return type — override stub annotation

const std = @import("std");
const ref_mod = @import("ref.zig");
const from_mod = @import("from.zig");
const source_parser_mod = @import("source_parser.zig");

/// How keyword arguments are handled for a function.
pub const KwargsMode = enum {
    /// All parameters are positional-only (METH_VARARGS).
    positional,
    /// Named kwargs via pyoz.Args(T) struct (METH_VARARGS | METH_KEYWORDS).
    args_struct,
    /// Auto-detected: required params are positional-only, ?T params are keyword-capable
    /// (METH_VARARGS | METH_KEYWORDS). Used by .from auto-scan.
    auto_kwargs,
};

/// Check if a field name indicates a private field (starts with underscore)
/// Private fields are not exposed to Python as properties or __init__ arguments
fn isPrivateField(comptime name: []const u8) bool {
    return name.len > 0 and name[0] == '_';
}

/// Check if a declaration is a get_X/set_X used as a property accessor.
fn isPropertyAccessor(comptime T: type, comptime decl_name: []const u8) bool {
    const fields = @typeInfo(T).@"struct".fields;
    // get_X is a property getter if it's a function
    if (decl_name.len > 4 and std.mem.startsWith(u8, decl_name, "get_")) {
        if (@typeInfo(@TypeOf(@field(T, decl_name))) == .@"fn") return true;
    }
    // set_X is a property setter if get_X exists as a function, or X is a struct field
    if (decl_name.len > 4 and std.mem.startsWith(u8, decl_name, "set_")) {
        if (@typeInfo(@TypeOf(@field(T, decl_name))) != .@"fn") return false;
        const prop_name = decl_name[4..];
        if (@hasDecl(T, "get_" ++ prop_name)) {
            if (@typeInfo(@TypeOf(@field(T, "get_" ++ prop_name))) == .@"fn") return true;
        }
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, prop_name)) return true;
        }
    }
    return false;
}

/// Coerce a comptime string declaration to []const u8.
/// Handles string literals (*const [N:0]u8), [*:0]const u8, and []const u8.
pub fn asSlice(comptime val: anytype) []const u8 {
    const T = @TypeOf(val);
    if (T == []const u8) return val;
    return std.mem.span(@as([*:0]const u8, val));
}

/// Extract the Nth parameter name from a comma-separated string.
/// e.g., getParamName("rule_name, depth", 1) -> "depth"
/// Falls back to "argN" if the index is out of range.
fn getParamName(comptime names_str: []const u8, comptime idx: usize) []const u8 {
    comptime {
        var current_idx: usize = 0;
        var start: usize = 0;
        var i: usize = 0;

        while (i <= names_str.len) : (i += 1) {
            if (i == names_str.len or names_str[i] == ',') {
                if (current_idx == idx) {
                    // Trim whitespace
                    var s = start;
                    var e = i;
                    while (s < e and names_str[s] == ' ') s += 1;
                    while (e > s and names_str[e - 1] == ' ') e -= 1;
                    return names_str[s..e];
                }
                current_idx += 1;
                start = i + 1;
            }
        }
        // Fallback if not enough names provided
        return std.fmt.comptimePrint("arg{d}", .{idx});
    }
}

/// Resolve the return type string for a method from its function signature.
fn resolveReturnType(comptime fn_info: anytype) []const u8 {
    comptime {
        if (fn_info.return_type) |ret| {
            const ret_info = @typeInfo(ret);
            if (ret_info == .error_union) {
                return zigTypeToPython(ret_info.error_union.payload);
            } else {
                return zigTypeToPython(ret);
            }
        }
        return "None";
    }
}

// =============================================================================
// Type Mapping: Zig Types -> Python Type Strings
// =============================================================================

/// Map a Zig type to its Python type annotation string
pub fn zigTypeToPython(comptime T: type) []const u8 {
    // Check for Signature wrapper first — use the user-provided stub string
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "_is_pyoz_signature")) {
        return T.stub_type;
    }

    const info = @typeInfo(T);

    return switch (info) {
        // Integer types -> int
        .int => "int",
        .comptime_int => "int",

        // Float types -> float
        .float => "float",
        .comptime_float => "float",

        // Bool -> bool
        .bool => "bool",

        // Void -> None
        .void => "None",

        // Pointers and slices
        .pointer => |ptr| {
            // String types
            if (ptr.size == .slice and ptr.child == u8) {
                return "str";
            }
            // Null-terminated string
            if (ptr.size == .many and ptr.child == u8) {
                return "str";
            }
            // String literal pointer
            if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array) {
                    const arr = child_info.array;
                    if (arr.child == u8) {
                        return "str";
                    }
                }
            }
            // Pointer to PyObject
            if (ptr.child == @import("python.zig").PyObject) {
                return "Any";
            }
            // Generic slice -> list[T]
            if (ptr.size == .slice) {
                return "list[" ++ zigTypeToPython(ptr.child) ++ "]";
            }
            // Pointer to class type - extract just the type name (strip module prefix)
            return extractTypeName(@typeName(ptr.child));
        },

        // Optional types -> T | None
        .optional => |opt| {
            const inner = zigTypeToPython(opt.child);
            return inner ++ " | None";
        },

        // Error unions - extract payload type
        .error_union => |eu| {
            return zigTypeToPython(eu.payload);
        },

        // Structs - check for known PyOZ types
        .@"struct" => {
            return mapStructType(T);
        },

        // Arrays
        .array => |arr| {
            return "list[" ++ zigTypeToPython(arr.child) ++ "]";
        },

        // Enums
        .@"enum" => extractTypeName(@typeName(T)),

        // Fallback
        else => "Any",
    };
}

/// Map struct types to Python equivalents
fn mapStructType(comptime T: type) []const u8 {
    // Use @hasDecl checks instead of string searching - much faster at comptime

    // Check for PyOZ marker declarations first (fastest checks)
    if (@hasDecl(T, "_is_pyoz_complex")) return "complex";
    if (@hasDecl(T, "_is_pyoz_datetime")) return "datetime.datetime";
    if (@hasDecl(T, "_is_pyoz_timedelta")) return "datetime.timedelta";
    if (@hasDecl(T, "_is_pyoz_date")) return "datetime.date";
    if (@hasDecl(T, "_is_pyoz_time")) return "datetime.time";
    if (@hasDecl(T, "_is_pyoz_bytearray")) return "bytearray";
    if (@hasDecl(T, "_is_pyoz_bytes")) return "bytes";
    if (@hasDecl(T, "_is_pyoz_path")) return "pathlib.Path";
    if (@hasDecl(T, "_is_pyoz_decimal")) return "decimal.Decimal";

    // Collection types - check by declaration pattern
    if (@hasDecl(T, "KeyType") and @hasDecl(T, "ValueType")) {
        // Dict-like type
        return "dict[" ++ zigTypeToPython(T.KeyType) ++ ", " ++ zigTypeToPython(T.ValueType) ++ "]";
    }

    if (@hasDecl(T, "_is_pyoz_frozenset")) {
        if (@hasDecl(T, "ElementType")) {
            return "frozenset[" ++ zigTypeToPython(T.ElementType) ++ "]";
        }
        return "frozenset[Any]";
    }

    if (@hasDecl(T, "_is_pyoz_set")) {
        if (@hasDecl(T, "ElementType")) {
            return "set[" ++ zigTypeToPython(T.ElementType) ++ "]";
        }
        return "set[Any]";
    }

    if (@hasDecl(T, "_is_pyoz_list")) {
        if (@hasDecl(T, "ElementType")) {
            return "list[" ++ zigTypeToPython(T.ElementType) ++ "]";
        }
        return "list[Any]";
    }

    if (@hasDecl(T, "_is_pyoz_iterator")) {
        if (@hasDecl(T, "ElementType")) {
            return "list[" ++ zigTypeToPython(T.ElementType) ++ "]";
        }
        return "list[Any]";
    }

    if (@hasDecl(T, "_is_pyoz_lazy_iterator")) {
        if (@hasDecl(T, "ElementType")) {
            return "Iterator[" ++ zigTypeToPython(T.ElementType) ++ "]";
        }
        return "Iterator[Any]";
    }

    // Dict producer type
    if (@hasDecl(T, "_is_pyoz_dict")) {
        if (@hasDecl(T, "KeyType") and @hasDecl(T, "ValueType")) {
            return "dict[" ++ zigTypeToPython(T.KeyType) ++ ", " ++ zigTypeToPython(T.ValueType) ++ "]";
        }
        return "dict[Any, Any]";
    }

    // Buffer types (numpy arrays)
    if (@hasDecl(T, "_is_pyoz_buffer") or @hasDecl(T, "_is_pyoz_buffer_mut")) {
        if (@hasDecl(T, "ElementType")) {
            const elem_type = T.ElementType;
            const numpy_dtype = zigTypeToNumpyDtype(elem_type);
            return "numpy.ndarray[Any, numpy.dtype[" ++ numpy_dtype ++ "]]";
        }
        return "numpy.ndarray[Any, Any]";
    }

    // Args wrapper - should be expanded by caller
    if (@hasDecl(T, "is_pyoz_args") and T.is_pyoz_args) {
        return "<<ARGS>>";
    }

    // Tuple structs
    const struct_info = @typeInfo(T).@"struct";
    if (struct_info.is_tuple) {
        var result: []const u8 = "tuple[";
        for (struct_info.fields, 0..) |field, i| {
            if (i > 0) result = result ++ ", ";
            result = result ++ zigTypeToPython(field.type);
        }
        return result ++ "]";
    }

    // Unknown struct - extract just the type name (strip module path)
    return extractTypeName(@typeName(T));
}

/// Extract just the type name from a fully qualified name like "lib.Point" -> "Point"
fn extractTypeName(comptime full_name: []const u8) []const u8 {
    // Find the last '.' and return everything after it
    var last_dot: usize = 0;
    var found_dot = false;
    for (full_name, 0..) |c, i| {
        if (c == '.') {
            last_dot = i;
            found_dot = true;
        }
    }
    if (found_dot) {
        return full_name[last_dot + 1 ..];
    }
    return full_name;
}

/// Map Zig numeric types to numpy dtype names
fn zigTypeToNumpyDtype(comptime T: type) []const u8 {
    return switch (T) {
        f64 => "numpy.float64",
        f32 => "numpy.float32",
        i64 => "numpy.int64",
        i32 => "numpy.int32",
        i16 => "numpy.int16",
        i8 => "numpy.int8",
        u64 => "numpy.uint64",
        u32 => "numpy.uint32",
        u16 => "numpy.uint16",
        u8 => "numpy.uint8",
        else => {
            const type_name = @typeName(T);
            if (std.mem.indexOf(u8, type_name, "Complex") != null) {
                if (std.mem.indexOf(u8, type_name, "Complex32") != null) {
                    return "numpy.complex64";
                }
                return "numpy.complex128";
            }
            return "Any";
        },
    };
}

// =============================================================================
// __text_signature__ / ml_doc builder
// =============================================================================

/// Method kind for text signature generation.
/// Determines the hidden parameter prefix that CPython strips from signatures.
pub const MethodKind = enum {
    module_func, // $module — module-level function
    instance_method, // $self — instance method
    static_method, // (none) — static method
    class_method, // $type — class method
};

/// Build an ml_doc string with an embedded __text_signature__.
///
/// CPython parses signatures from ml_doc using the Argument Clinic format:
///   "funcname($module, arg0, arg1, /)\n--\n\nDocstring text"
///
/// The signature portion is extracted as __text_signature__ and used by
/// help() and inspect.signature() to show proper parameter names.
pub fn buildMlDoc(
    comptime name: []const u8,
    comptime Fn: type,
    comptime kind: MethodKind,
    comptime kwargs_mode: KwargsMode,
    comptime doc: ?[*:0]const u8,
    comptime param_names: ?[]const u8,
) [*:0]const u8 {
    comptime {
        const fn_info = @typeInfo(Fn).@"fn";
        const params = fn_info.params;

        var result: []const u8 = name ++ "(";

        // Hidden parameter prefix (stripped by inspect)
        const hidden: ?[]const u8 = switch (kind) {
            .module_func => "$module",
            .instance_method => "$self",
            .class_method => "$type",
            .static_method => null,
        };

        switch (kwargs_mode) {
            .args_struct => {
                // Named kwargs: funcname($module, /, field1, field2=None)
                var need_comma = false;
                if (hidden) |h| {
                    result = result ++ h ++ ", /";
                    need_comma = true;
                }

                // Args param is last: index 0 for module funcs, 1 for methods
                const args_param_idx: usize = switch (kind) {
                    .instance_method, .class_method => 1,
                    .module_func, .static_method => 0,
                };
                if (params.len > args_param_idx) {
                    const ArgsWrapperType = params[args_param_idx].type.?;
                    if (@typeInfo(ArgsWrapperType) == .@"struct" and @hasDecl(ArgsWrapperType, "ArgsStruct")) {
                        const ArgsStructType = ArgsWrapperType.ArgsStruct;
                        const args_fields = @typeInfo(ArgsStructType).@"struct".fields;

                        for (args_fields) |field| {
                            if (need_comma) {
                                result = result ++ ", ";
                            }
                            result = result ++ field.name;
                            if (field.default_value_ptr != null or @typeInfo(field.type) == .optional) {
                                result = result ++ "=None";
                            }
                            need_comma = true;
                        }
                    }
                }
            },
            .auto_kwargs => {
                // Auto kwargs: funcname($module, req1, req2, /, opt1=None, opt2=None)
                var has_any = false;
                if (hidden) |h| {
                    result = result ++ h;
                    has_any = true;
                }

                const skip: usize = switch (kind) {
                    .instance_method, .class_method => 1,
                    .module_func, .static_method => 0,
                };

                // First pass: required (non-optional) params — positional-only
                var arg_idx: usize = 0;
                for (params[skip..]) |param| {
                    if (param.type) |ptype| {
                        if (@typeInfo(ptype) != .optional) {
                            if (has_any) result = result ++ ", ";
                            if (param_names) |pn| {
                                result = result ++ getParamName(pn, arg_idx);
                            } else {
                                result = result ++ std.fmt.comptimePrint("arg{d}", .{arg_idx});
                            }
                            has_any = true;
                        }
                        arg_idx += 1;
                    }
                }

                // Positional-only separator
                if (has_any) {
                    result = result ++ ", /";
                }

                // Second pass: optional (?T) params — keyword-capable
                arg_idx = 0;
                for (params[skip..]) |param| {
                    if (param.type) |ptype| {
                        if (@typeInfo(ptype) == .optional) {
                            result = result ++ ", ";
                            if (param_names) |pn| {
                                result = result ++ getParamName(pn, arg_idx);
                            } else {
                                result = result ++ std.fmt.comptimePrint("arg{d}", .{arg_idx});
                            }
                            result = result ++ "=None";
                        }
                        arg_idx += 1;
                    }
                }
            },
            .positional => {
                // Regular positional: funcname($module, arg0, arg1, /)
                var has_any = false;
                if (hidden) |h| {
                    result = result ++ h;
                    has_any = true;
                }

                // Skip self/cls parameter for instance/class methods
                const skip: usize = switch (kind) {
                    .instance_method, .class_method => 1,
                    .module_func, .static_method => 0,
                };

                var arg_idx: usize = 0;
                for (params[skip..]) |param| {
                    if (param.type) |ptype| {
                        if (has_any) result = result ++ ", ";
                        if (param_names) |pn| {
                            result = result ++ getParamName(pn, arg_idx);
                        } else {
                            result = result ++ std.fmt.comptimePrint("arg{d}", .{arg_idx});
                        }
                        // Mark optional parameters
                        if (@typeInfo(ptype) == .optional) {
                            result = result ++ "=None";
                        }
                        has_any = true;
                        arg_idx += 1;
                    }
                }

                // Mark as positional-only (trailing /)
                if (has_any) {
                    result = result ++ ", /";
                }
            },
        }

        result = result ++ ")\n--\n\n";

        // Append docstring
        if (doc) |d| {
            result = result ++ std.mem.span(d);
        }

        return from_mod.comptimeStrZ(result);
    }
}

// =============================================================================
// Stub Writer
// =============================================================================

/// Comptime buffer for building stub content
pub fn StubWriter(comptime max_size: usize) type {
    return struct {
        buffer: [max_size]u8 = undefined,
        pos: usize = 0,

        const Self = @This();

        pub fn write(self: *Self, data: []const u8) void {
            if (self.pos + data.len <= max_size) {
                @memcpy(self.buffer[self.pos..][0..data.len], data);
                self.pos += data.len;
            }
        }

        pub fn writeLine(self: *Self, data: []const u8) void {
            self.write(data);
            self.write("\n");
        }

        pub fn writeIndent(self: *Self, level: usize) void {
            var i: usize = 0;
            while (i < level * 4) : (i += 1) {
                self.write(" ");
            }
        }

        /// Returns a comptime-constant string slice that can be used at runtime
        pub fn getWritten(self: *const Self) *const [self.pos]u8 {
            return self.buffer[0..self.pos];
        }
    };
}

// =============================================================================
// Stub Generation Functions
// =============================================================================

/// Generate the imports section of the stub file
pub fn generateImports(comptime config: anytype) []const u8 {
    @setEvalBranchQuota(std.math.maxInt(u32));
    comptime {
        var result: []const u8 = "\"\"\"Type stubs generated by PyOZ\"\"\"\n\n";
        result = result ++ "from typing import Any, Iterable, Iterator, overload\n";

        // Check if we need specific imports based on types used
        var needs_datetime = false;
        var needs_decimal = false;
        var needs_pathlib = false;
        var needs_numpy = false;

        // Check functions
        const funcs = if (@hasField(@TypeOf(config), "funcs")) config.funcs else &.{};
        for (funcs) |f| {
            const func_imports = detectImportsForFunc(@TypeOf(f.func));
            needs_datetime = needs_datetime or func_imports.datetime;
            needs_decimal = needs_decimal or func_imports.decimal;
            needs_pathlib = needs_pathlib or func_imports.pathlib;
            needs_numpy = needs_numpy or func_imports.numpy;
        }

        // Check classes
        if (@hasField(@TypeOf(config), "classes")) {
            const classes = config.classes;
            for (classes) |cls| {
                const class_imports = detectImportsForClass(cls.zig_type);
                needs_datetime = needs_datetime or class_imports.datetime;
                needs_decimal = needs_decimal or class_imports.decimal;
                needs_pathlib = needs_pathlib or class_imports.pathlib;
                needs_numpy = needs_numpy or class_imports.numpy;
            }
        }

        if (needs_datetime) {
            result = result ++ "import datetime\n";
        }
        if (needs_decimal) {
            result = result ++ "import decimal\n";
        }
        if (needs_pathlib) {
            result = result ++ "import pathlib\n";
        }
        if (needs_numpy) {
            result = result ++ "import numpy\n";
        }

        result = result ++ "\n";

        return result;
    }
}

const ImportFlags = struct {
    datetime: bool = false,
    decimal: bool = false,
    pathlib: bool = false,
    numpy: bool = false,
};

fn detectImportsForFunc(comptime Fn: type) ImportFlags {
    const fn_info = @typeInfo(Fn).@"fn";
    var flags = ImportFlags{};

    // Check return type
    if (fn_info.return_type) |ret| {
        const ret_flags = detectImportsForType(ret);
        flags.datetime = flags.datetime or ret_flags.datetime;
        flags.decimal = flags.decimal or ret_flags.decimal;
        flags.pathlib = flags.pathlib or ret_flags.pathlib;
        flags.numpy = flags.numpy or ret_flags.numpy;
    }

    // Check parameters
    for (fn_info.params) |param| {
        if (param.type) |ptype| {
            const param_flags = detectImportsForType(ptype);
            flags.datetime = flags.datetime or param_flags.datetime;
            flags.decimal = flags.decimal or param_flags.decimal;
            flags.pathlib = flags.pathlib or param_flags.pathlib;
            flags.numpy = flags.numpy or param_flags.numpy;
        }
    }

    return flags;
}

fn detectImportsForClass(comptime T: type) ImportFlags {
    const struct_info = @typeInfo(T).@"struct";
    var flags = ImportFlags{};

    // Check fields (skip Ref fields — they are internal references)
    for (struct_info.fields) |field| {
        if (ref_mod.isRefType(field.type)) continue;
        const field_flags = detectImportsForType(field.type);
        flags.datetime = flags.datetime or field_flags.datetime;
        flags.decimal = flags.decimal or field_flags.decimal;
        flags.pathlib = flags.pathlib or field_flags.pathlib;
        flags.numpy = flags.numpy or field_flags.numpy;
    }

    return flags;
}

fn detectImportsForType(comptime T: type) ImportFlags {
    // Use @hasDecl checks instead of string searching for speed
    const info = @typeInfo(T);

    // Handle optionals and error unions
    if (info == .optional) {
        return detectImportsForType(info.optional.child);
    }
    if (info == .error_union) {
        return detectImportsForType(info.error_union.payload);
    }
    if (info == .pointer) {
        return detectImportsForType(info.pointer.child);
    }

    // Check struct types for PyOZ markers
    if (info == .@"struct") {
        // Unwrap Signature to detect imports for the inner type
        if (@hasDecl(T, "_is_pyoz_signature")) {
            return detectImportsForType(T.inner_type);
        }
        return .{
            .datetime = @hasDecl(T, "_is_pyoz_datetime") or @hasDecl(T, "_is_pyoz_date") or
                @hasDecl(T, "_is_pyoz_time") or @hasDecl(T, "_is_pyoz_timedelta"),
            .decimal = @hasDecl(T, "_is_pyoz_decimal"),
            .pathlib = @hasDecl(T, "_is_pyoz_path"),
            .numpy = @hasDecl(T, "_is_pyoz_buffer") or @hasDecl(T, "_is_pyoz_buffer_mut"),
        };
    }

    return .{};
}

/// Generate stub for a single function
pub fn generateFunctionStub(
    comptime name: []const u8,
    comptime Fn: type,
    comptime doc: ?[]const u8,
    comptime kwargs_mode: KwargsMode,
    comptime param_names: ?[]const u8,
) []const u8 {
    comptime {
        var result: []const u8 = "def " ++ name ++ "(";
        const fn_info = @typeInfo(Fn).@"fn";
        const params = fn_info.params;

        switch (kwargs_mode) {
            .args_struct => {
                if (params.len == 1) {
                    // Named kwargs - expand the Args struct
                    const ArgsWrapperType = params[0].type.?;
                    if (@typeInfo(ArgsWrapperType) == .@"struct" and @hasDecl(ArgsWrapperType, "ArgsStruct")) {
                        const ArgsStructType = ArgsWrapperType.ArgsStruct;
                        const args_fields = @typeInfo(ArgsStructType).@"struct".fields;

                        var first = true;
                        for (args_fields) |field| {
                            if (!first) {
                                result = result ++ ", ";
                            }
                            first = false;

                            result = result ++ field.name ++ ": ";

                            // Check if optional
                            const field_info = @typeInfo(field.type);
                            if (field_info == .optional) {
                                result = result ++ zigTypeToPython(field_info.optional.child) ++ " | None";
                            } else {
                                result = result ++ zigTypeToPython(field.type);
                            }

                            // Check for default value
                            if (field.default_value_ptr != null) {
                                result = result ++ " = ...";
                            } else if (field_info == .optional) {
                                result = result ++ " = None";
                            }
                        }
                    }
                }
            },
            .auto_kwargs => {
                // Auto kwargs: required params positional, ?T params keyword-capable
                // def func(req1: int, req2: str, /, *, opt1: int | None = None) -> ...
                var has_required = false;
                var arg_idx: usize = 0;

                // First: required (non-optional) params
                for (params) |param| {
                    if (param.type) |ptype| {
                        if (@typeInfo(ptype) != .optional) {
                            if (has_required or arg_idx > 0) result = result ++ ", ";
                            const pname = if (param_names) |pn|
                                getParamName(pn, arg_idx)
                            else
                                std.fmt.comptimePrint("arg{d}", .{arg_idx});
                            result = result ++ pname ++ ": " ++ zigTypeToPython(ptype);
                            has_required = true;
                        }
                        arg_idx += 1;
                    }
                }

                // Positional-only separator + keyword section
                var has_optional = false;
                for (params) |param| {
                    if (param.type) |ptype| {
                        if (@typeInfo(ptype) == .optional) {
                            has_optional = true;
                            break;
                        }
                    }
                }

                if (has_optional) {
                    if (has_required) {
                        result = result ++ ", /";
                    }

                    arg_idx = 0;
                    for (params) |param| {
                        if (param.type) |ptype| {
                            if (@typeInfo(ptype) == .optional) {
                                result = result ++ ", ";
                                const pname = if (param_names) |pn|
                                    getParamName(pn, arg_idx)
                                else
                                    std.fmt.comptimePrint("arg{d}", .{arg_idx});
                                const inner_type = @typeInfo(ptype).optional.child;
                                result = result ++ pname ++ ": " ++ zigTypeToPython(inner_type) ++ " | None = None";
                            }
                            arg_idx += 1;
                        }
                    }
                }
            },
            .positional => {
                // Regular positional arguments
                var arg_idx: usize = 0;
                for (params) |param| {
                    if (param.type) |ptype| {
                        if (arg_idx > 0) {
                            result = result ++ ", ";
                        }

                        const pname = if (param_names) |pn|
                            getParamName(pn, arg_idx)
                        else
                            std.fmt.comptimePrint("arg{d}", .{arg_idx});
                        result = result ++ pname ++ ": " ++ zigTypeToPython(ptype);
                        arg_idx += 1;
                    }
                }
            },
        }

        result = result ++ ") -> ";

        // Return type
        if (fn_info.return_type) |ret| {
            const ret_info = @typeInfo(ret);
            if (ret_info == .error_union) {
                result = result ++ zigTypeToPython(ret_info.error_union.payload);
            } else {
                result = result ++ zigTypeToPython(ret);
            }
        } else {
            result = result ++ "None";
        }

        result = result ++ ":\n";

        // Docstring
        if (doc) |d| {
            result = result ++ "    \"\"\"" ++ d ++ "\"\"\"\n";
        }

        result = result ++ "    ...\n\n";

        return result;
    }
}

/// Generate stub for a class
pub fn generateClassStub(comptime name: []const u8, comptime T: type, comptime base: ?[]const u8, comptime parsed_source: ?source_parser_mod.ParsedSource) []const u8 {
    comptime {
        const source_parser = source_parser_mod;
        var result: []const u8 = if (base) |b|
            "class " ++ name ++ "(" ++ b ++ "):\n"
        else
            "class " ++ name ++ ":\n";
        const struct_info = @typeInfo(T).@"struct";
        const fields = struct_info.fields;

        // Class docstring — emit actual content from __doc__ or source-parsed /// comment
        if (@hasDecl(T, "__doc__")) {
            result = result ++ "    \"\"\"" ++ asSlice(@field(T, "__doc__")) ++ "\"\"\"\n";
        } else if (parsed_source) |parsed| {
            if (source_parser.getDoc(parsed, name)) |doc| {
                result = result ++ "    \"\"\"" ++ doc ++ "\"\"\"\n";
            }
        }

        // Detect if this is a PyOZ subclass
        const is_pyoz_sub = @hasDecl(T, "__base__") and
            @TypeOf(T.__base__) == type and
            @hasDecl(T.__base__, "_is_pyoz_base");

        // Fields as class-level annotations (skip private and Ref fields)
        // For PyOZ subclasses, include parent fields first
        var has_public_fields = false;
        if (is_pyoz_sub) {
            const parent_fields = @typeInfo(T.__base__.ParentType).@"struct".fields;
            for (parent_fields) |field| {
                if (isPrivateField(field.name)) continue;
                if (ref_mod.isRefType(field.type)) continue;
                result = result ++ "    " ++ field.name ++ ": " ++ zigTypeToPython(field.type) ++ "\n";
                has_public_fields = true;
            }
        }
        for (fields) |field| {
            if (isPrivateField(field.name)) continue;
            if (ref_mod.isRefType(field.type)) continue;
            result = result ++ "    " ++ field.name ++ ": " ++ zigTypeToPython(field.type) ++ "\n";
            has_public_fields = true;
        }

        if (has_public_fields) {
            result = result ++ "\n";
        }

        // __init__ method — for PyOZ subclasses, include parent fields first
        result = result ++ "    def __init__(self";
        if (is_pyoz_sub) {
            const parent_fields = @typeInfo(T.__base__.ParentType).@"struct".fields;
            for (parent_fields) |field| {
                if (isPrivateField(field.name)) continue;
                if (ref_mod.isRefType(field.type)) continue;
                result = result ++ ", " ++ field.name ++ ": " ++ zigTypeToPython(field.type);
            }
        }
        for (fields) |field| {
            if (isPrivateField(field.name)) continue;
            if (ref_mod.isRefType(field.type)) continue;
            result = result ++ ", " ++ field.name ++ ": " ++ zigTypeToPython(field.type);
        }
        result = result ++ ") -> None: ...\n\n";

        // Instance methods, static methods, class methods
        for (struct_info.decls) |decl| {
            // Skip private and special declarations
            if (decl.name[0] == '_') continue;
            if (std.mem.startsWith(u8, decl.name, "classattr_")) continue;

            // Skip stub annotation declarations
            if (std.mem.endsWith(u8, decl.name, "__doc__")) continue;
            if (std.mem.endsWith(u8, decl.name, "__params__")) continue;

            // Skip get_X/set_X that are used as property getters/setters
            if (isPropertyAccessor(T, decl.name)) continue;

            const decl_value = @field(T, decl.name);
            const DeclType = @TypeOf(decl_value);

            if (@typeInfo(DeclType) == .@"fn") {
                // Look up optional method docstring (explicit > source-parsed)
                const method_doc: ?[]const u8 = if (@hasDecl(T, decl.name ++ "__doc__"))
                    asSlice(@field(T, decl.name ++ "__doc__"))
                else if (parsed_source) |parsed| blk: {
                    break :blk source_parser.getMethodDoc(parsed, name, decl.name);
                } else null;
                // Look up optional method param names (explicit > source-parsed)
                const method_params: ?[]const u8 = if (@hasDecl(T, decl.name ++ "__params__"))
                    asSlice(@field(T, decl.name ++ "__params__"))
                else if (parsed_source) |parsed| blk: {
                    break :blk source_parser.getMethodParams(parsed, name, decl.name);
                } else null;
                result = result ++ generateMethodStub(decl.name, DeclType, T, method_doc, method_params);
            }
        }

        // Computed properties (get_X / set_X)
        for (struct_info.decls) |decl| {
            if (std.mem.startsWith(u8, decl.name, "get_")) {
                // Must be a function, not a constant (e.g. get_error__doc__)
                if (@typeInfo(@TypeOf(@field(T, decl.name))) != .@"fn") continue;
                const prop_name = decl.name[4..];
                // Check if there's a corresponding setter
                const has_setter = @hasDecl(T, "set_" ++ prop_name);

                const getter_fn = @field(T, decl.name);
                const getter_info = @typeInfo(@TypeOf(getter_fn)).@"fn";
                const return_type = if (getter_info.return_type) |ret| zigTypeToPython(ret) else "Any";

                result = result ++ "    @property\n";
                result = result ++ "    def " ++ prop_name ++ "(self) -> " ++ return_type ++ ": ...\n";

                if (has_setter) {
                    result = result ++ "    @" ++ prop_name ++ ".setter\n";
                    result = result ++ "    def " ++ prop_name ++ "(self, value: " ++ return_type ++ ") -> None: ...\n";
                }
                result = result ++ "\n";
            }
        }

        // pyoz.property() declarations
        for (struct_info.decls) |decl| {
            const DeclType = @TypeOf(@field(T, decl.name));
            // Check if this is a type with __pyoz_property__ marker
            if (DeclType == type) {
                const ActualType = @field(T, decl.name);
                if (@hasDecl(ActualType, "__pyoz_property__") and ActualType.__pyoz_property__) {
                    const ConfigType = ActualType.config;
                    // Get return type from the getter function
                    const getter_fn = @field(ConfigType{}, "get");
                    const getter_info = @typeInfo(@TypeOf(getter_fn)).@"fn";
                    const return_type = if (getter_info.return_type) |ret| zigTypeToPython(ret) else "Any";

                    const has_setter = @hasField(ConfigType, "set");

                    result = result ++ "    @property\n";
                    result = result ++ "    def " ++ decl.name ++ "(self) -> " ++ return_type ++ ": ...\n";

                    if (has_setter) {
                        result = result ++ "    @" ++ decl.name ++ ".setter\n";
                        result = result ++ "    def " ++ decl.name ++ "(self, value: " ++ return_type ++ ") -> None: ...\n";
                    }
                    result = result ++ "\n";
                }
            }
        }

        // Magic methods with fixed return types (these never vary)
        for (.{
            .{ "__repr__", "str" },
            .{ "__str__", "str" },
            .{ "__hash__", "int" },
            .{ "__len__", "int" },
            .{ "__bool__", "bool" },
            .{ "__int__", "int" },
            .{ "__float__", "float" },
            .{ "__complex__", "complex" },
            .{ "__index__", "int" },
        }) |magic| {
            if (@hasDecl(T, magic[0])) {
                result = result ++ "    def " ++ magic[0] ++ "(self) -> " ++ magic[1] ++ ": ...\n";
            }
        }

        // __iter__ — introspect return type
        if (@hasDecl(T, "__iter__")) {
            const iter_info = @typeInfo(@TypeOf(@field(T, "__iter__"))).@"fn";
            const iter_ret = iter_info.return_type.?;
            const iter_ret_info = @typeInfo(iter_ret);
            // If returns *Self, it's a self-iterator — derive element type from __next__
            if (iter_ret_info == .pointer and iter_ret_info.pointer.child == T) {
                if (@hasDecl(T, "__next__")) {
                    const next_info = @typeInfo(@TypeOf(@field(T, "__next__"))).@"fn";
                    const next_ret = next_info.return_type.?;
                    const next_ret_info = @typeInfo(next_ret);
                    if (next_ret_info == .optional) {
                        result = result ++ "    def __iter__(self) -> Iterator[" ++ zigTypeToPython(next_ret_info.optional.child) ++ "]: ...\n";
                    } else if (next_ret_info == .error_union) {
                        const payload_info = @typeInfo(next_ret_info.error_union.payload);
                        if (payload_info == .optional) {
                            result = result ++ "    def __iter__(self) -> Iterator[" ++ zigTypeToPython(payload_info.optional.child) ++ "]: ...\n";
                        } else {
                            result = result ++ "    def __iter__(self) -> Iterator[" ++ zigTypeToPython(next_ret_info.error_union.payload) ++ "]: ...\n";
                        }
                    } else {
                        result = result ++ "    def __iter__(self) -> Iterator[" ++ zigTypeToPython(next_ret) ++ "]: ...\n";
                    }
                } else {
                    result = result ++ "    def __iter__(self) -> Iterator[Any]: ...\n";
                }
            } else {
                result = result ++ "    def __iter__(self) -> " ++ zigTypeToPython(iter_ret) ++ ": ...\n";
            }
        }

        // __next__ — unwrap optional (None = StopIteration in Python)
        if (@hasDecl(T, "__next__")) {
            const next_info = @typeInfo(@TypeOf(@field(T, "__next__"))).@"fn";
            const next_ret = next_info.return_type.?;
            const next_ret_info = @typeInfo(next_ret);
            if (next_ret_info == .optional) {
                result = result ++ "    def __next__(self) -> " ++ zigTypeToPython(next_ret_info.optional.child) ++ ": ...\n";
            } else if (next_ret_info == .error_union) {
                const payload_info = @typeInfo(next_ret_info.error_union.payload);
                if (payload_info == .optional) {
                    result = result ++ "    def __next__(self) -> " ++ zigTypeToPython(payload_info.optional.child) ++ ": ...\n";
                } else {
                    result = result ++ "    def __next__(self) -> " ++ zigTypeToPython(next_ret_info.error_union.payload) ++ ": ...\n";
                }
            } else {
                result = result ++ "    def __next__(self) -> " ++ zigTypeToPython(next_ret) ++ ": ...\n";
            }
        }

        // __call__ — introspect full signature
        if (@hasDecl(T, "__call__")) {
            const call_info = @typeInfo(@TypeOf(@field(T, "__call__"))).@"fn";
            const call_params = call_info.params;
            result = result ++ "    def __call__(self";
            // Check for parameter name override (explicit > source-parsed > fallback)
            const has_explicit_call_params = @hasDecl(T, "__call____params__");
            const call_params_str: []const u8 = if (has_explicit_call_params)
                asSlice(@field(T, "__call____params__"))
            else if (parsed_source) |parsed| blk: {
                break :blk source_parser.getMethodParams(parsed, name, "__call__") orelse "";
            } else "";
            const has_call_params = call_params_str.len > 0;
            var cidx: usize = 0;
            for (call_params[1..]) |param| {
                if (param.type) |ptype| {
                    const pname = if (has_call_params)
                        getParamName(call_params_str, cidx)
                    else
                        std.fmt.comptimePrint("arg{d}", .{cidx});
                    result = result ++ ", " ++ pname ++ ": " ++ zigTypeToPython(ptype);
                    cidx += 1;
                }
            }
            result = result ++ ") -> " ++ resolveReturnType(call_info) ++ ": ...\n";
        }

        // __enter__ — introspect return type
        if (@hasDecl(T, "__enter__")) {
            const enter_info = @typeInfo(@TypeOf(@field(T, "__enter__"))).@"fn";
            const enter_ret = enter_info.return_type.?;
            const enter_ret_info = @typeInfo(enter_ret);
            if (enter_ret_info == .pointer and enter_ret_info.pointer.child == T) {
                result = result ++ "    def __enter__(self) -> " ++ name ++ ": ...\n";
            } else {
                result = result ++ "    def __enter__(self) -> " ++ zigTypeToPython(enter_ret) ++ ": ...\n";
            }
        }

        // Comparison methods
        for (.{ "__eq__", "__ne__", "__lt__", "__le__", "__gt__", "__ge__" }) |cmp| {
            if (@hasDecl(T, cmp)) {
                result = result ++ "    def " ++ cmp ++ "(self, other: " ++ name ++ ") -> bool: ...\n";
            }
        }

        // Binary operators
        for (.{
            .{ "__add__", name },
            .{ "__sub__", name },
            .{ "__mul__", name },
            .{ "__truediv__", name },
            .{ "__floordiv__", name },
            .{ "__mod__", name },
            .{ "__pow__", name },
            .{ "__matmul__", name },
            .{ "__and__", name },
            .{ "__or__", name },
            .{ "__xor__", name },
            .{ "__lshift__", name },
            .{ "__rshift__", name },
        }) |op| {
            if (@hasDecl(T, op[0])) {
                result = result ++ "    def " ++ op[0] ++ "(self, other: " ++ op[1] ++ ") -> " ++ name ++ ": ...\n";
            }
        }

        // Unary operators
        for (.{
            .{ "__neg__", name },
            .{ "__pos__", name },
            .{ "__abs__", name },
            .{ "__invert__", name },
        }) |op| {
            if (@hasDecl(T, op[0])) {
                result = result ++ "    def " ++ op[0] ++ "(self) -> " ++ op[1] ++ ": ...\n";
            }
        }

        // Sequence/mapping methods — introspect actual types
        if (@hasDecl(T, "__getitem__")) {
            const gi_info = @typeInfo(@TypeOf(@field(T, "__getitem__"))).@"fn";
            const gi_key_type = zigTypeToPython(gi_info.params[1].type.?);
            const gi_ret = gi_info.return_type.?;
            const gi_ret_info = @typeInfo(gi_ret);
            const gi_value_type = if (gi_ret_info == .error_union)
                zigTypeToPython(gi_ret_info.error_union.payload)
            else
                zigTypeToPython(gi_ret);
            result = result ++ "    def __getitem__(self, key: " ++ gi_key_type ++ ") -> " ++ gi_value_type ++ ": ...\n";
        }
        if (@hasDecl(T, "__setitem__")) {
            const si_info = @typeInfo(@TypeOf(@field(T, "__setitem__"))).@"fn";
            const si_key_type = zigTypeToPython(si_info.params[1].type.?);
            const si_val_type = zigTypeToPython(si_info.params[2].type.?);
            result = result ++ "    def __setitem__(self, key: " ++ si_key_type ++ ", value: " ++ si_val_type ++ ") -> None: ...\n";
        }
        if (@hasDecl(T, "__delitem__")) {
            const di_info = @typeInfo(@TypeOf(@field(T, "__delitem__"))).@"fn";
            const di_key_type = zigTypeToPython(di_info.params[1].type.?);
            result = result ++ "    def __delitem__(self, key: " ++ di_key_type ++ ") -> None: ...\n";
        }
        if (@hasDecl(T, "__contains__")) {
            const ct_info = @typeInfo(@TypeOf(@field(T, "__contains__"))).@"fn";
            const ct_item_type = zigTypeToPython(ct_info.params[1].type.?);
            result = result ++ "    def __contains__(self, item: " ++ ct_item_type ++ ") -> bool: ...\n";
        }

        // Context manager
        if (@hasDecl(T, "__exit__")) {
            result = result ++ "    def __exit__(self, exc_type: type[BaseException] | None, exc_val: BaseException | None, exc_tb: Any) -> bool | None: ...\n";
        }

        result = result ++ "\n";

        return result;
    }
}

/// Generate stub for a single method
fn generateMethodStub(comptime name: []const u8, comptime Fn: type, comptime ClassType: type, comptime doc: ?[]const u8, comptime param_names_override: ?[]const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        const fn_info = @typeInfo(Fn).@"fn";
        const params = fn_info.params;

        // Check for parameter name override
        const has_param_names = param_names_override != null or @hasDecl(ClassType, name ++ "__params__");
        const param_names_str: []const u8 = if (param_names_override) |pn|
            pn
        else if (@hasDecl(ClassType, name ++ "__params__"))
            asSlice(@field(ClassType, name ++ "__params__"))
        else
            "";

        if (params.len == 0) {
            // No parameters - static method
            result = result ++ "    @staticmethod\n    def " ++ name ++ "(";
        } else {
            const first_param = params[0].type.?;
            const first_info = @typeInfo(first_param);

            // Check if first param is self (pointer to class)
            const is_self = first_info == .pointer and
                (first_info.pointer.child == ClassType);

            // Check if first param is cls (comptime type)
            const is_classmethod = first_param == type;

            if (is_classmethod) {
                result = result ++ "    @classmethod\n    def " ++ name ++ "(cls";
            } else if (is_self) {
                result = result ++ "    def " ++ name ++ "(self";
            } else {
                // Static method
                result = result ++ "    @staticmethod\n    def " ++ name ++ "(";
                // First param is not self, include it
                const p0name = if (has_param_names) getParamName(param_names_str, 0) else "arg0";
                result = result ++ p0name ++ ": " ++ zigTypeToPython(first_param);
            }

            // Rest of parameters
            const start_idx: usize = if (is_self or is_classmethod) 1 else 1;
            var param_idx: usize = if (is_self or is_classmethod) 0 else 1;

            for (params[start_idx..]) |param| {
                if (param.type) |ptype| {
                    const pname = if (has_param_names)
                        getParamName(param_names_str, param_idx)
                    else
                        std.fmt.comptimePrint("arg{d}", .{param_idx});
                    result = result ++ ", " ++ pname ++ ": " ++ zigTypeToPython(ptype);
                    param_idx += 1;
                }
            }
        }

        result = result ++ ") -> ";

        // Return type
        result = result ++ resolveReturnType(fn_info);

        if (doc) |d| {
            result = result ++ ":\n";
            result = result ++ "        \"\"\"" ++ d ++ "\"\"\"\n";
            result = result ++ "        ...\n";
        } else {
            result = result ++ ": ...\n";
        }

        return result;
    }
}

/// Generate stub for an exception
pub fn generateExceptionStub(comptime name: []const u8, comptime doc: ?[]const u8) []const u8 {
    comptime {
        var result: []const u8 = "class " ++ name ++ "(Exception):\n";
        if (doc) |d| {
            result = result ++ "    \"\"\"" ++ d ++ "\"\"\"\n";
        }
        result = result ++ "    ...\n\n";
        return result;
    }
}

/// Generate stub for a module constant
pub fn generateConstStub(comptime name: []const u8, comptime T: type) []const u8 {
    comptime {
        return name ++ ": " ++ zigTypeToPython(T) ++ "\n";
    }
}

/// Generate stub for an enum
pub fn generateEnumStub(comptime name: []const u8, comptime T: type, comptime is_str_enum: bool) []const u8 {
    comptime {
        var result: []const u8 = "class " ++ name;
        const enum_info = @typeInfo(T).@"enum";

        if (is_str_enum) {
            result = result ++ "(str, Enum):\n";
        } else {
            result = result ++ "(int, Enum):\n";
        }

        // Enum members — annotate with type, don't expose values
        const member_type: []const u8 = if (is_str_enum) "str" else "int";
        for (enum_info.fields) |field| {
            result = result ++ "    " ++ field.name ++ ": " ++ member_type ++ "\n";
        }

        result = result ++ "\n";

        return result;
    }
}

// =============================================================================
// Main Stub Generator
// =============================================================================

/// Generate complete stub file content for a module
pub fn generateModuleStubs(comptime config: anytype) []const u8 {
    @setEvalBranchQuota(std.math.maxInt(u32));
    comptime {
        // Build result using pure comptime concatenation (no mutable vars)
        var result: []const u8 = "";

        // Imports
        result = result ++ generateImports(config);

        // Check if we have enums - need Enum import
        const has_enums = (@hasField(@TypeOf(config), "enums") and config.enums.len > 0) or
            (@hasField(@TypeOf(config), "str_enums") and config.str_enums.len > 0) or
            (@hasField(@TypeOf(config), "from") and from_mod.countAllFromEnums(config.from, from_mod.buildExplicitNameSet(config)) > 0);
        if (has_enums) {
            // Insert enum import after other imports
            result = result ++ "from enum import Enum\n\n";
        }

        // Exceptions — skip those that are also registered as classes (merged below)
        if (@hasField(@TypeOf(config), "exceptions")) {
            const exceptions = config.exceptions;
            for (exceptions) |exc| {
                const exc_name = std.mem.span(exc.name);
                var is_also_class = false;
                if (@hasField(@TypeOf(config), "classes")) {
                    for (config.classes) |cls| {
                        if (std.mem.eql(u8, std.mem.span(cls.name), exc_name)) {
                            is_also_class = true;
                        }
                    }
                }
                if (!is_also_class) {
                    result = result ++ generateExceptionStub(
                        exc_name,
                        if (exc.doc) |d| std.mem.span(d) else null,
                    );
                }
            }
        }

        // Enums (unified - uses is_str_enum field for auto-detection)
        if (@hasField(@TypeOf(config), "enums")) {
            const enums = config.enums;
            for (enums) |e| {
                result = result ++ generateEnumStub(std.mem.span(e.name), e.zig_type, e.is_str_enum);
            }
        }

        // Legacy str_enums support (deprecated)
        if (@hasField(@TypeOf(config), "str_enums")) {
            const str_enums = config.str_enums;
            for (str_enums) |e| {
                // Legacy str_enums always use is_str_enum if available, else default true
                const is_str = if (@hasField(@TypeOf(e), "is_str_enum")) e.is_str_enum else true;
                result = result ++ generateEnumStub(std.mem.span(e.name), e.zig_type, is_str);
            }
        }

        // Classes — merge with exception base if also registered as exception
        if (@hasField(@TypeOf(config), "classes")) {
            const classes = config.classes;
            for (classes) |cls| {
                const cls_name = std.mem.span(cls.name);
                // Check for PyOZ parent class
                var base_name: ?[]const u8 = null;
                if (@hasDecl(cls.zig_type, "__base__")) {
                    const BaseDecl = @TypeOf(cls.zig_type.__base__);
                    if (BaseDecl == type and @hasDecl(cls.zig_type.__base__, "_is_pyoz_base")) {
                        const ParentType = cls.zig_type.__base__.ParentType;
                        // Find parent class name in the classes list
                        for (classes) |parent_cls| {
                            if (parent_cls.zig_type == ParentType) {
                                base_name = std.mem.span(parent_cls.name);
                            }
                        }
                    }
                }
                // Exception base takes priority if both are set
                if (@hasField(@TypeOf(config), "exceptions")) {
                    for (config.exceptions) |exc| {
                        if (std.mem.eql(u8, std.mem.span(exc.name), cls_name)) {
                            base_name = "Exception";
                        }
                    }
                }
                result = result ++ generateClassStub(cls_name, cls.zig_type, base_name, null);
            }
        }

        // Module-level constants
        if (@hasField(@TypeOf(config), "consts")) {
            const consts = config.consts;
            if (consts.len > 0) {
                result = result ++ "# Module constants\n";
                for (consts) |c| {
                    result = result ++ generateConstStub(std.mem.span(c.name), c.value_type);
                }
                result = result ++ "\n";
            }
        }

        // Functions
        const funcs = if (@hasField(@TypeOf(config), "funcs")) config.funcs else &.{};
        for (funcs) |f| {
            const mode: KwargsMode = if (@hasField(@TypeOf(f), "is_named_kwargs") and f.is_named_kwargs) .args_struct else .positional;
            result = result ++ generateFunctionStub(
                std.mem.span(f.name),
                @TypeOf(f.func),
                if (f.doc) |d| std.mem.span(d) else null,
                mode,
                null,
            );
        }

        // === .from auto-scanned entries ===
        if (@hasField(@TypeOf(config), "from")) {
            const explicit_names = from_mod.buildExplicitNameSet(config);
            const from_entries = config.from;

            for (from_entries) |entry| {
                if (from_mod.isSub(entry)) continue;
                const ns = from_mod.resolveNamespace(entry);
                const opts = from_mod.getSourceOptions(entry);
                const decls = @typeInfo(ns).@"struct".decls;

                // .from exceptions
                for (decls) |d| {
                    if (from_mod.shouldExportAsException(ns, d.name, opts, explicit_names)) {
                        const ExcMarker = @field(ns, d.name);
                        const exc_doc_val = ExcMarker._exc_doc;
                        result = result ++ generateExceptionStub(
                            d.name,
                            if (exc_doc_val) |dv| std.mem.span(dv) else null,
                        );
                    }
                }

                // .from enums
                for (decls) |d| {
                    if (from_mod.shouldExportAsEnum(ns, d.name, opts, explicit_names)) {
                        const EnumType = @field(ns, d.name);
                        const is_str = !from_mod.isIntEnum(EnumType);
                        result = result ++ generateEnumStub(d.name, EnumType, is_str);
                    }
                }

                // .from classes
                for (decls) |d| {
                    if (from_mod.shouldExportAsClass(ns, d.name, opts, explicit_names)) {
                        const ClassType = @field(ns, d.name);
                        const class_parsed = from_mod.resolveParsedSource(entry);
                        result = result ++ generateClassStub(d.name, ClassType, null, class_parsed);
                    }
                }

                // .from constants
                {
                    var has_from_consts = false;
                    for (decls) |d| {
                        if (from_mod.shouldExportAsConstant(ns, d.name, opts, explicit_names)) {
                            if (!has_from_consts) {
                                result = result ++ "# Module constants\n";
                                has_from_consts = true;
                            }
                            const ConstType = @TypeOf(@field(ns, d.name));
                            result = result ++ generateConstStub(d.name, ConstType);
                        }
                    }
                    if (has_from_consts) {
                        result = result ++ "\n";
                    }
                }

                // .from functions
                for (decls) |d| {
                    if (from_mod.shouldExportAsFunction(ns, d.name, opts, explicit_names)) {
                        const func_val = @field(ns, d.name);
                        const FnType = @TypeOf(func_val);
                        const from_param_names = from_mod.getParamNames(entry, d.name);
                        const mode: KwargsMode = if (from_mod.isNamedKwargsFunc(FnType))
                            .args_struct
                        else if (from_mod.hasOptionalParams(FnType) and from_param_names != null)
                            .auto_kwargs
                        else
                            .positional;
                        const doc_val = from_mod.getDocstring(entry, d.name);
                        result = result ++ generateFunctionStub(
                            d.name,
                            FnType,
                            if (doc_val) |dv| std.mem.span(dv) else null,
                            mode,
                            from_param_names,
                        );
                    }
                }
            }

            // .from submodules (generate as nested classes with static methods)
            for (from_entries) |entry| {
                if (from_mod.isSub(entry)) {
                    const sub_name = std.mem.span(from_mod.getSubName(entry));
                    const sub_ns = from_mod.resolveNamespace(entry);
                    const sub_opts = from_mod.getSourceOptions(entry);
                    const sub_decls = @typeInfo(sub_ns).@"struct".decls;

                    result = result ++ "class " ++ sub_name ++ ":\n";
                    var has_members = false;

                    for (sub_decls) |sd| {
                        if (from_mod.shouldExportAsFunction(sub_ns, sd.name, sub_opts, &.{})) {
                            const sfunc = @field(sub_ns, sd.name);
                            const SFnType = @TypeOf(sfunc);
                            const s_doc = from_mod.getDocstring(entry, sd.name);
                            // Generate as staticmethod
                            result = result ++ "    @staticmethod\n";
                            // Indent the function stub
                            const s_params = from_mod.getParamNames(entry, sd.name);
                            const s_mode: KwargsMode = if (from_mod.isNamedKwargsFunc(SFnType))
                                .args_struct
                            else if (from_mod.hasOptionalParams(SFnType) and s_params != null)
                                .auto_kwargs
                            else
                                .positional;
                            const fn_stub = generateFunctionStub(
                                sd.name,
                                SFnType,
                                if (s_doc) |sv| std.mem.span(sv) else null,
                                s_mode,
                                s_params,
                            );
                            // Add 4-space indent to each line
                            var line_start: usize = 0;
                            for (fn_stub, 0..) |ch, ci| {
                                if (ch == '\n') {
                                    result = result ++ "    " ++ fn_stub[line_start .. ci + 1];
                                    line_start = ci + 1;
                                }
                            }
                            if (line_start < fn_stub.len) {
                                result = result ++ "    " ++ fn_stub[line_start..];
                            }
                            has_members = true;
                        }

                        if (from_mod.shouldExportAsConstant(sub_ns, sd.name, sub_opts, &.{})) {
                            const SConstType = @TypeOf(@field(sub_ns, sd.name));
                            result = result ++ "    " ++ generateConstStub(sd.name, SConstType);
                            has_members = true;
                        }
                    }

                    if (!has_members) {
                        result = result ++ "    ...\n";
                    }
                    result = result ++ "\n";
                }
            }
        }

        return result;
    }
}
