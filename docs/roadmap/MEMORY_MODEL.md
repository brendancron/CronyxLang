# Memory Model

## Overview

Cronyx is a high-level language. Allocation is implicit — you create objects and the runtime manages the memory. Users never call `alloc()` or deal with raw pointers. This is the same model as Java, Python, and most modern languages.

## Semantics

**Reference semantics for compound types.** Assignment copies the pointer, not the object:

```cx
var y = x;  // y and x point to the same struct on the heap
```

Primitives (`int`, `bool`) are unboxed and copied by value. Everything else is a pointer.

## LLVM Type Layouts

These are the concrete heap/stack representations the LLVM backend will use.

| Type | Representation |
|---|---|
| `int` | `i64` — unboxed on stack |
| `bool` | `i8` — unboxed on stack |
| `string` | `{ i64 len, i8* data }` on heap — immutable, length-prefixed |
| `struct S` | malloc'd `{ field0, field1, ... }`, passed as pointer |
| `[T]` (list) | malloc'd `{ i64 len, i64 cap, T* data }` — Go-style slice header |
| `tuple` | Same layout as anonymous struct |
| `enum` | malloc'd `{ i64 tag, [max_payload bytes] }` — tagged union |
| `fn`/closure | `{ fn_ptr, env_ptr }` — see Closures below |

These defaults follow Go and Koka conventions and can be revised later.

## Closures

Every closure (lambda or effect continuation) is represented as:

```
{ fn_ptr: *fn(env_ptr, arg0, arg1, ...), env_ptr: *ClosureEnv }
```

`ClosureEnv` is a malloc'd struct containing exactly the free variables captured by that closure. The function pointer takes `env_ptr` as its first argument (standard C closure encoding). The env struct layout is determined per-closure by free variable analysis (LLVM roadmap Phase 3).

This is the same approach Koka uses.

## Strings

Immutable and length-prefixed (`{ i64 len, i8* data }`). String concatenation always allocates a new string. Safe to share under reference semantics since strings cannot be mutated.

## `free(obj)`

Until a garbage collector exists, Cronyx exposes a single manual memory builtin:

```cx
free(obj);
```

- Takes any value, returns `unit`
- At the interpreter level: no-op (Rust's Rc handles cleanup)
- At LLVM level: calls `free()` on the underlying heap pointer — **shallow only**
- **Unsafe** — use-after-free is possible and the compiler does not prevent it
- Explicitly temporary. Once a GC is implemented, `free` will be removed.

## What is NOT in Cronyx

- No raw pointers in the type system
- No `alloc(size)` function
- No `ptr` type
- No manual allocator threading (unlike Zig)
