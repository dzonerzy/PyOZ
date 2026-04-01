# Classes

PyOZ exposes Zig structs as Python classes automatically. Define a struct, register it with `pyoz.class()`, and PyOZ generates a full Python class with constructor, properties, and methods.

## Defining a Class

```zig
const Point = struct {
    x: f64,
    y: f64,
};

pub const MyModule = pyoz.module(.{
    .name = "mymodule",
    .classes = &.{
        pyoz.class("Point", Point),
    },
});
```

This automatically creates:

- A constructor: `Point(x=1.0, y=2.0)`
- Read/write properties for `x` and `y`
- Automatic type conversion between Zig and Python

## Private Fields

Fields starting with an underscore (`_`) are treated as **private** and are not exposed to Python:

```zig
const MyClass = struct {
    // Public fields - exposed to Python
    name: []const u8,
    value: i64,

    // Private fields - NOT exposed to Python
    _internal_counter: i64,
    _cache: ?SomeType,
};
```

Private fields:

- Are **NOT** exposed as Python properties (accessing `obj._internal_counter` raises `AttributeError`)
- Are **NOT** included in `__init__` arguments (only `name` and `value` above)
- Are **NOT** included in generated `.pyi` type stubs
- Are initialized using their default values if provided, zero-initialized if the type supports it, or left undefined otherwise
- Can still be accessed and modified by Zig methods

This is useful for:

- Internal implementation details that shouldn't be part of the public API
- Fields with types that can't be converted to Python (e.g., Zig-specific structs)
- Caches, buffers, or state that users shouldn't manipulate directly

```zig
const Counter = struct {
    count: i64,           // Public: users can read/write this
    _step: i64,           // Private: internal implementation detail

    pub fn increment(self: *Counter) void {
        self.count += self._step;  // Methods can access private fields
    }
};
```

Python usage:
```python
c = Counter(0)      # Only public field in __init__
c.count             # OK: 0
c.increment()       # OK: uses _step internally
c._step             # AttributeError: private field not exposed
```

## Constructors

By default, the constructor accepts all struct fields as arguments. For custom initialization, define `__new__`:

```zig
pub fn __new__(initial: i64, step: ?i64) Counter {
    return .{ .count = initial, .step = step orelse 1 };
}
```

Optional parameters (`?T`) become keyword arguments with `None` as default.

`__new__` supports error union and optional return types for validation:

```zig
// Error union — Zig errors become Python exceptions automatically
pub fn __new__(capacity: i64) !Ring {
    if (capacity <= 0) return error.InvalidCapacity;
    return .{ .capacity = capacity };
}

// Optional — raise a specific exception, then return null
pub fn __new__(capacity: i64) ?Ring {
    if (capacity <= 0) return pyoz.raiseValueError("capacity must be positive");
    return .{ .capacity = capacity };
}
```

## Methods

PyOZ auto-detects method types based on the first parameter:

| First Parameter | Method Type | Python Usage |
|-----------------|-------------|--------------|
| `*Self` or `*const Self` | Instance method | `obj.method()` |
| `comptime cls: type` | Class method | `Class.method()` |
| Anything else | Static method | `Class.method()` |

Use `*const Self` for methods that don't modify the instance.

### Keyword Arguments on Methods

Methods can use `pyoz.Args(T)` for keyword arguments, just like module-level functions:

```zig
const Point = struct {
    x: f64,
    y: f64,

    pub fn translate(self: *Point, args: pyoz.Args(struct {
        dx: f64 = 0,
        dy: f64 = 0,
    })) void {
        self.x += args.value.dx;
        self.y += args.value.dy;
    }
};
```

Python: `p.translate(dx=3.0)`, `p.translate(1.0, 2.0)`, or `p.translate()`

Struct fields with defaults become optional keyword arguments,
same as [module-level keyword functions](functions.md#keyword-arguments-pyozkwfunc).

## Docstrings

Add documentation using special constants:

| Constant | Purpose |
|----------|---------|
| `pub const __doc__` | Class docstring |
| `pub const fieldname__doc__` | Field docstring |
| `pub const methodname__doc__` | Method docstring |

All must be `[*:0]const u8` type.

## Magic Methods

PyOZ supports Python's special methods. Define them as regular Zig functions with matching names.

All magic methods support three return conventions: plain `T` (always succeeds), `!T` (error union — Zig errors automatically become Python exceptions), and `?T` (optional — raise an exception with `pyoz.raiseValueError()` etc., then return `null`). See [Error Handling in Magic Methods](errors.md#error-handling-in-magic-methods) for examples.

### Operators

| Category | Methods |
|----------|---------|
| Arithmetic | `__add__`, `__sub__`, `__mul__`, `__truediv__`, `__floordiv__`, `__mod__`, `__pow__`, `__matmul__` |
| Unary | `__neg__`, `__pos__`, `__abs__`, `__invert__` |
| Comparison | `__eq__`, `__ne__`, `__lt__`, `__le__`, `__gt__`, `__ge__` |
| Bitwise | `__and__`, `__or__`, `__xor__`, `__lshift__`, `__rshift__` |
| In-place | `__iadd__`, `__isub__`, `__imul__`, etc. |
| Reflected | `__radd__`, `__rsub__`, `__rmul__`, etc. |

**Signature pattern:** Binary operators take `(self: *const T, other: *const T)` and return `T`. In-place operators take `(self: *T, other: *const T)` and return `void`. Reflected operators take `(self: *const T, other: *pyoz.PyObject)` for handling Python scalars.

### String Representation

| Method | Purpose |
|--------|---------|
| `__repr__` | Developer representation (shown in REPL) |
| `__str__` | User-friendly string (`str(obj)`) |
| `__hash__` | Hash value for use in sets/dicts |

**`__hash__` and `__eq__` interaction:** Following Python semantics, if you define `__eq__` without `__hash__`, PyOZ automatically makes the class unhashable — calling `hash()` raises `TypeError`, and instances cannot be used in sets or as dict keys. To make an equality-comparable class hashable, define both `__eq__` and `__hash__`:

```zig
const Point = struct {
    x: i64,
    y: i64,

    pub fn __eq__(self: *const Point, other: *const Point) bool {
        return self.x == other.x and self.y == other.y;
    }

    pub fn __hash__(self: *const Point) i64 {
        return self.x *% 31 +% self.y;
    }
};
```

`__hash__` supports plain `i64`, `!i64` (error union), and `?i64` (optional — return `null` to raise `TypeError`).

Both `__repr__` and `__str__` support two signatures:

```zig
// Buffered (recommended) — PyOZ provides a 4096-byte buffer you can write into.
// The returned slice must point into `buf`. This avoids use-after-free when
// formatting with std.fmt.bufPrint.
pub fn __repr__(self: *const MyStruct, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "MyStruct(x={d})", .{self.x}) catch "MyStruct(?)";
}

// Literal-only — safe ONLY when returning a string literal or other
// static/comptime-known data. Returning a slice into a local stack buffer
// is undefined behavior.
pub fn __repr__(self: *const MyStruct) []const u8 {
    _ = self;
    return "MyStruct(...)";
}
```

### Type Conversion

| Method | Purpose |
|--------|---------|
| `__bool__` | Boolean evaluation (`if obj:`) |
| `__int__` | `int(obj)` |
| `__float__` | `float(obj)` |
| `__index__` | Used in slicing, `range()`, etc. |
| `__complex__` | `complex(obj)` |

### Callable Objects

Define `__call__` to make instances callable:

```zig
pub fn __call__(self: *const Adder, x: i64) i64 {
    return self.value + x;
}
```

Python: `adder = Adder(10); adder(5)  # 15`

## Protocols

### Sequence Protocol

Make your class behave like a list:

| Method | Python Syntax |
|--------|---------------|
| `__len__` | `len(obj)` |
| `__getitem__(index: i64) !T` | `obj[i]` |
| `__setitem__(index: i64, value: T) !void` | `obj[i] = value` |
| `__delitem__(index: i64) !void` | `del obj[i]` |
| `__contains__(value: T) bool` | `value in obj` |

Return errors (e.g., `error.IndexOutOfBounds`) to raise Python exceptions. Negative indices are passed as-is; handle them in your implementation.

### Iterator Protocol

| Method | Purpose |
|--------|---------|
| `__iter__(self: *T) *T` | Return iterator (usually self) |
| `__next__(self: *T) ?T` | Return next item or `null` for StopIteration |
| `__reversed__(self: *T) *T` | Return reversed iterator |

Store iteration state in instance fields.

### Context Manager Protocol

| Method | Purpose |
|--------|---------|
| `__enter__(self: *T) *T` | Enter `with` block, return context |
| `__exit__(self: *T) bool` | Exit block; return `true` to suppress exceptions |

### Descriptor Protocol

For custom attribute behavior on other classes:

| Method | Purpose |
|--------|---------|
| `__get__(self, obj: ?*PyObject) T` | Attribute access |
| `__set__(self, obj: ?*PyObject, value: T)` | Attribute assignment |
| `__delete__(self, obj: ?*PyObject)` | Attribute deletion |

### Dynamic Attributes

| Method | Purpose |
|--------|---------|
| `__getattr__(name: []const u8) !T` | Called when attribute not found |
| `__setattr__(name: []const u8, value: *PyObject)` | Called for all attribute assignments |
| `__delattr__(name: []const u8) !void` | Called when deleting attribute |

## Generic Type Syntax (`__class_getitem__`)

Enable `MyClass[int]` subscript syntax (PEP 560) by declaring a single constant:

```zig
const Point = struct {
    x: f64,
    y: f64,

    pub const __class_getitem__ = true;
};
```

Python:
```python
Point[int]          # returns types.GenericAlias on Python 3.9+
Point[int, float]   # multiple type parameters
```

This is useful for type annotations and generic patterns:
```python
def transform(points: list[Point[float]]) -> Point[float]:
    ...
```

Works in ABI3 mode. On Python 3.8, falls back to returning the class itself.

## Class Configuration

### Frozen (Immutable) Classes

```zig
pub const __frozen__: bool = true;
```

Prevents attribute modification. Frozen classes should implement `__hash__` and `__eq__`.

### Feature Flags

```zig
pub const __features__ = .{ .dict = true, .weakref = true };
```

- `.dict = true` - Enables dynamic attribute storage (`obj.custom = "value"`)
- `.weakref = true` - Enables weak references

### Class Attributes

Prefix constants with `classattr_` to make them class-level:

```zig
pub const classattr_PI: f64 = 3.14159;
```

Python: `Circle.PI  # 3.14159`

### Freelist (Object Pooling)

For classes that are frequently created and destroyed, enable a freelist to reuse deallocated objects instead of going through the allocator:

```zig
const Token = struct {
    kind: i64,
    start: i64,
    end: i64,

    pub const __freelist__: usize = 32;  // pool up to 32 objects
};
```

When an object is garbage-collected, it's pushed onto the freelist instead of being freed. The next `Token(...)` call reuses a pooled object, skipping allocation. Objects are fully re-initialized on reuse.

Only applies to simple types (no `__dict__`, no weakrefs). The freelist is a fixed-size static array — once full, excess objects are freed normally.

### Inheritance from Built-in Types

Extend Python built-in types:

```zig
pub const __base__ = pyoz.bases.list;  // or pyoz.bases.dict
```

Use `pyoz.object(self)` to get the underlying Python object for calling Python API functions.

For dict subclasses, implement `__missing__` to handle missing keys.

### Inheritance Between PyOZ Classes

One PyOZ class can inherit from another using `pyoz.base(Parent)`. The child struct declares `__base__` and embeds the parent as `_parent` (must be the first field):

```zig
const Animal = struct {
    name: []const u8,
    age: i64,

    pub fn speak(self: *const Animal) []const u8 {
        _ = self;
        return "...";
    }
};

const Dog = struct {
    pub const __base__ = pyoz.base(Animal);

    _parent: Animal,       // Must be first field, embeds parent data
    breed: []const u8,     // Child's own field

    pub fn fetch(self: *const Dog) []const u8 {
        _ = self;
        return "fetching!";
    }
};

pub const Module = pyoz.module(.{
    .name = "animals",
    .classes = &.{
        pyoz.class("Animal", Animal),  // Parent must come first
        pyoz.class("Dog", Dog),
    },
});
```

Python usage:

```python
d = Dog("Rex", 3, "Labrador")   # parent fields first, then child fields
d.name                            # "Rex" — inherited property
d.speak()                         # "..." — inherited method
d.breed                           # "Labrador" — own property
d.fetch()                         # "fetching!" — own method
isinstance(d, Animal)             # True
Dog.__mro__                       # [Dog, Animal, object]
```

Key rules:

- The parent class **must** be listed before the child in the `classes` array (comptime error otherwise)
- The child's first field must be `_parent: ParentType` (comptime validated)
- Parent methods and properties are inherited via Python's MRO — no duplication needed
- The child's `__init__` accepts a flattened argument list: parent public fields first, then child public fields
- `isinstance()` works correctly — `Dog` instances pass `isinstance(d, Animal)`
- Functions accepting `*const Animal` will also accept `Dog` instances (via `PyObject_TypeCheck`)
- Stubs generate `class Dog(Animal):` with the correct flattened constructor signature

## GC Support

For classes holding Python object references, implement garbage collection hooks to allow Python's cyclic garbage collector to detect and break reference cycles:

| Method | Signature | Purpose |
|--------|-----------|---------|
| `__traverse__` | `fn(self: *T, visitor: pyoz.GCVisitor) c_int` | Report held references |
| `__clear__` | `fn(self: *T) void` | Release references to break cycles |

The `GCVisitor` is passed **by value** (not by pointer). Call `visitor.call()` for each `?*PyObject` field and check its return value:

```zig
const Observer = struct {
    name: [64]u8,
    name_len: usize,
    _callback: ?*pyoz.PyObject,   // Held Python reference
    _target: ?*pyoz.PyObject,     // Another held reference

    pub fn __traverse__(self: *Observer, visitor: pyoz.GCVisitor) c_int {
        // Visit each Python object reference. Return immediately if non-zero.
        var ret = visitor.call(self._callback);
        if (ret != 0) return ret;
        ret = visitor.call(self._target);
        if (ret != 0) return ret;
        return 0;
    }

    pub fn __clear__(self: *Observer) void {
        // Release references to break cycles
        if (self._callback) |cb| pyoz.py.Py_DecRef(cb);
        self._callback = null;
        if (self._target) |t| pyoz.py.Py_DecRef(t);
        self._target = null;
    }
};
```

Only implement GC hooks for classes that store `?*PyObject` fields. Classes with only Zig-native fields (integers, floats, arrays, etc.) don't need GC support.

## Custom Cleanup (`__del__`)

Define `__del__` to run custom cleanup when Python garbage-collects your object. This is called during `tp_dealloc`, before the object is freed.

```zig
const Resource = struct {
    handle: i64,
    _freed: bool,

    pub fn __new__(handle: i64) Resource {
        return .{ .handle = handle, ._freed = false };
    }

    pub fn __del__(self: *Resource) void {
        // Free C memory, close file handles, release resources, etc.
        self._freed = true;
        self.handle = -1;
    }

    pub fn is_valid(self: *const Resource) bool {
        return self.handle >= 0 and !self._freed;
    }
};
```

Python:
```python
r = Resource(42)
r.is_valid()  # True
del r         # __del__ runs automatically
```

**Signature:** `pub fn __del__(self: *Self) void`

`__del__` is called before weakref cleanup, `__dict__` cleanup, and object deallocation, so all fields and state are still accessible. Works in both normal and ABI3 modes. Types that don't define `__del__` have zero overhead — the check is resolved at compile time.

Use this for C interop structs that allocate memory, open file descriptors, or hold external resources that need explicit cleanup.

## Method Chaining

Methods returning `*Self` or `*const Self` enable chaining. PyOZ automatically handles Python reference counting:

```zig
pub fn add(self: *Builder, n: i64) *Builder {
    self.value += n;
    return self;
}
```

Python: `b.add(1).add(2).add(3)`

## Cross-Class References

When a module defines multiple classes, methods on one class can accept or return instances of another class in the same module. PyOZ handles this automatically — no special syntax needed.

```zig
const Point = struct {
    x: f64,
    y: f64,

    pub fn magnitude(self: *const Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
};

const Line = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,

    /// Returns a Point — cross-class return
    pub fn start_point(self: *const Line) Point {
        return .{ .x = self.x1, .y = self.y1 };
    }

    /// Accepts two Points — cross-class arguments
    pub fn from_points(p1: *const Point, p2: *const Point) Line {
        return .{ .x1 = p1.x, .y1 = p1.y, .x2 = p2.x, .y2 = p2.y };
    }
};

pub const MyModule = pyoz.module(.{
    .name = "geometry",
    .classes = &.{
        pyoz.class("Point", Point),
        pyoz.class("Line", Line),
    },
});
```

Python:
```python
import geometry

p1 = geometry.Point(1.0, 2.0)
p2 = geometry.Point(4.0, 6.0)

line = geometry.Line.from_points(p1, p2)  # accepts Point instances
start = line.start_point()                # returns a Point instance
print(start.magnitude())                  # full Point API works
```

Cyclic references work too — class A methods can accept/return class B and vice versa, as long as both are registered in the same module.

### Manual Conversion with `Module.toPy()`

The examples above use direct Zig return types (`Point`, `Line`) which PyOZ converts automatically. When you need to build raw Python objects manually (e.g., a Python list of class instances), use the module-level converter:

```zig
/// Returns a Python list of Point objects
pub fn vertices(self: *const Polygon) ?*pyoz.PyObject {
    const list = pyoz.py.PyList_New(0) orelse return null;
    for (self.points) |pt| {
        // Module.toPy knows about Point — wraps it as a Python Point object
        const obj = Module.toPy(Point, pt) orelse {
            pyoz.py.Py_DecRef(list);
            return null;
        };
        _ = pyoz.py.PyList_Append(list, obj);
        pyoz.py.Py_DecRef(obj);
    }
    return list;
}
```

> **Note:** `pyoz.Conversions.toPy()` does **not** know about registered classes and will return `null` for class types. Always use `Module.toPy()` when converting class instances manually.

## Strong Object References (`Ref(T)`)

When one PyOZ class needs to hold a reference to another, use `pyoz.Ref(T)` to prevent use-after-free. Without `Ref(T)`, if Python garbage-collects the referenced object while another object still points to it, the pointer becomes dangling.

`Ref(T)` wraps a `?*PyObject` with automatic `Py_IncRef` on `set()` and `Py_DecRef` on `clear()` and object deallocation.

```zig
const Owner = struct {
    value: i64,
};

const Child = struct {
    _owner: pyoz.Ref(Owner),   // Strong reference — keeps Owner alive
    tag: i64,

    pub fn get_owner_value(self: *const Child) ?i64 {
        const owner = self._owner.get(MyModule.registered_classes) orelse return null;
        return owner.value;
    }

    pub fn has_owner(self: *const Child) bool {
        return self._owner.object() != null;
    }
};
```

### Setting a Ref

To set a `Ref`, you need the `*PyObject` of the target. Use `Module.selfObject(T, ptr)` to recover it from a `*const T` data pointer:

```zig
fn make_child(owner: *const Owner, tag: i64) Child {
    var child = Child{ .tag = tag, ._owner = .{} };
    child._owner.set(MyModule.selfObject(Owner, owner));
    return child;
}
```

### Ref API

| Method | Description |
|--------|-------------|
| `ref.set(py_obj)` | Store reference (INCREFs new, DECREFs old) |
| `ref.get(class_infos)` | Get `?*const T` to referenced data |
| `ref.getMut(class_infos)` | Get `?*T` to referenced data |
| `ref.object()` | Get raw `?*PyObject` (borrowed) |
| `ref.clear()` | Release reference (DECREF + set null) |

### Automatic Behavior

- **Excluded from Python**: `Ref` fields are automatically excluded from Python properties, `__init__` parameters, stub generation, and auto-doc signatures — whether the field name starts with `_` or not
- **Deallocation**: References are released in `tp_dealloc` before the object is freed
- **Freelist-safe**: References are cleared before freelist push, and `std.mem.zeroes` on pop prevents double-free

## Stub Customization

PyOZ auto-generates `.pyi` type stubs from your Zig code. Most types are inferred automatically, but three opt-in conventions let you fine-tune the output:

### Docstrings

Class and method docstrings are propagated to stubs:

```zig
const Node = struct {
    pub const __doc__: [*:0]const u8 = "A node in the parse tree.";
    pub const rule__doc__: [*:0]const u8 = "Return the grammar rule name.";

    pub fn rule(self: *const Node) []const u8 { ... }
};
```

Generated stub:
```python
class Node:
    """A node in the parse tree."""
    def rule(self) -> str:
        """Return the grammar rule name."""
        ...
```

### Return Type Override (`Signature`)

When a method returns `?T` only to signal errors (not to return `None`), or returns `?*pyoz.PyObject` for a complex type, the inferred stub annotation won't match the actual Python API. Use `pyoz.Signature(T, "stub_string")` as the return type to override it:

```zig
const Node = struct {
    pub fn children(self: *const Node) pyoz.Signature(?*pyoz.PyObject, "list[Node]") {
        const list = buildChildList(self) orelse {
            _ = pyoz.raiseRuntimeError("failed to build children");
            return .{ .value = null };
        };
        return .{ .value = list };
    }

    pub fn find(self: *const Node, name: []const u8) pyoz.Signature(?Node, "Node") {
        // null signals an error, not a None return
        return .{ .value = self.doFind(name) orelse {
            _ = pyoz.raiseKeyError("not found");
            return .{ .value = null };
        }};
    }
};
```

Generated stub:
```python
def children(self) -> list[Node]: ...
def find(self, arg0: str) -> Node: ...
```

`Signature` works the same way for instance methods, static methods, and class methods. See [Return Type Override](stubs.md#return-type-override-signature) for full details.

### Parameter Names (`__params__`)

Zig's `@typeInfo` does not expose function parameter names, so stubs and `help()` default to `arg0, arg1, ...`. For `.from` module-level functions, [`pyoz.withSource()`](from.md#source-introspection-with-withsource) extracts real parameter names automatically. For class methods, use the `__params__` convention to override:

```zig
const Node = struct {
    pub const find__params__: []const u8 = "rule_name";
    pub const child__params__: []const u8 = "index";

    pub fn find(self: *const Node, name: []const u8) ?*pyoz.PyObject { ... }
    pub fn child(self: *const Node, idx: i64) ?Node { ... }
};
```

Generated stub:
```python
def find(self, rule_name: str) -> Any | None: ...
def child(self, index: int) -> Node | None: ...
```

Names are comma-separated (excluding `self`). If fewer names are provided than parameters, remaining ones fall back to `argN`.

## Next Steps

- [Properties](properties.md) - Custom getters/setters
- [Types](types.md) - Type conversion reference
- [Errors](errors.md) - Exception handling
