# Memory Model: Allocation as an Algebraic Effect

## Overview

Cronyx treats memory allocation as an algebraic effect rather than a language primitive. This gives programs the same flexibility as Zig (swap allocators freely, no hidden global state) without Zig's ergonomic cost (no explicit allocator threading through every function signature).

The key insight: an allocator is a resource handler. Effect handlers are already the mechanism for managing resources (open, resume, close). Allocation maps cleanly onto this pattern.

---

## The Pattern

### Zig (explicit allocator threading)

```zig
fn do_work(allocator: std.mem.Allocator) ![]u8 {
    const buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);
    // ...
}
```

Every function that allocates must accept an allocator parameter. This is safe and flexible but pervasive — allocators appear in signatures everywhere.

### Cronyx (allocator as effect)

```cx
effect Alloc {
    fn alloc(size: int): ptr
    fn dealloc(p: ptr): unit
}

fn do_work(): []u8 with <Alloc> {
    var buf = alloc(1024);
    // ...
    return buf;
}
```

The `<Alloc>` annotation in the return type signals that `do_work` requires an allocation handler in scope. The allocator itself is not a parameter — it is part of the ambient effect context.

---

## Handler Patterns

### Simple allocation (`fn` handler)

For allocators that don't need cleanup interleaved with the continuation:

```cx
handler HeapAlloc: Alloc {
    fn alloc(size: int): ptr {
        return malloc(size);
    }
    fn dealloc(p: ptr): unit {
        free(p);
    }
}

with HeapAlloc {
    do_work();
}
```

### RAII via `ctl` (arena allocator)

`ctl` handlers intercept the operation and hold the continuation. This enables setup-before, cleanup-after semantics — exactly what arena allocation needs:

```cx
handler ArenaAlloc: Alloc {
    ctl alloc(size: int): ptr {
        var p = arena_alloc(current_arena, size);
        resume(p);
        // code here runs after the continuation finishes (if continuation returns)
    }
    fn dealloc(p: ptr): unit {
        // no-op: arena frees all at once
    }
}

with ArenaAlloc {
    do_work();
    // when this block exits, arena is reset
}
```

The `ctl` form is equivalent to:

```
alloc(size) → before-code → resume(ptr) → after-code
                                ↑
                     continuation runs here
```

This RAII-via-`ctl` pattern naturally expresses:
- Bump allocators (alloc fast, no per-dealloc overhead)
- Pool allocators (track all allocations, free batch on scope exit)
- Leak-checking allocators (count allocs, assert dealloc count matches on scope exit)
- Instrumented allocators (log size/site on alloc, report on exit)

---

## The Pervasiveness Problem

Allocation is everywhere. If every function that allocates must declare `<Alloc>` in its signature, the annotation becomes noise — present in nearly every function, carrying no useful information.

Two design options:

### Model A: Ambient Effect (recommended)

`Alloc` is a built-in ambient effect. It does not appear in function signatures by default. The compiler knows every function may allocate; the programmer installs a handler at program startup (or at a region boundary) without annotating call sites.

```cx
// Main installs the default allocator — no annotations needed anywhere
with HeapAlloc {
    main();
}
```

Functions that want to *restrict* allocation (e.g., interrupt handlers, real-time code) can explicitly declare `<pure>` or `<no Alloc>` to make the compiler reject allocating operations inside them.

**Analogy**: Rust's global allocator. Allocation is always available; you opt in to changing it at boundaries. Unlike Rust, Cronyx makes the substitution compositional — different regions of a program can use different allocators without unsafe.

### Model B: Explicit Effect

`<Alloc>` appears in every function signature that allocates, flows through the type system, and must be satisfied at each call site.

```cx
fn build_list(): []int with <Alloc> { ... }
fn process(data: []int): unit with <Alloc> { ... }
fn pipeline(): unit with <Alloc> {
    process(build_list());
}
```

**Advantage**: Maximum visibility. The compiler statically knows which functions allocate.
**Disadvantage**: Near-universal annotation. In a language where most data structures are heap-allocated, this becomes mechanical boilerplate.

### Recommendation

Start with **Model A**. Add opt-in `<no Alloc>` constraints for code that must be allocation-free (real-time, embedded). This matches programmer expectations (allocation is not usually surprising) while still enabling Zig-style allocator flexibility at region boundaries.

Model B can be layered on later as an opt-in strictness mode if the ecosystem demands it.

---

## Comparison with Other Languages

| | **Cronyx (Model A)** | **Zig** | **Rust** | **GC languages** |
|---|---|---|---|---|
| Allocator swappable | Yes, at any scope boundary | Yes, but explicit | Via GlobalAlloc (unsafe) | No (usually) |
| Allocator in signatures | No (ambient) | Yes (always) | No | No |
| Composable allocators | Yes (handler nesting) | Manual | No | No |
| Static allocation-free verification | `<no Alloc>` annotation | Comptime/no-alloc coding style | Manual | No |
| RAII / dealloc timing | `ctl` handler | `defer` | Drop trait | GC |
| Per-scope allocator | Yes, natively | Yes, manually | No | No |

---

## Interaction with CPS Transform

Cronyx already implements a selective CPS transform for effect handling. The `Alloc` effect integrates with this in two scenarios:

### Case 1: `fn` handlers (no continuation capture)

`fn alloc(size)` does not capture the continuation — it computes a value and returns. The CPS transform produces ordinary function calls. No overhead beyond a vtable-style dispatch to the current handler.

### Case 2: `ctl` handlers (continuation capture)

`ctl alloc(size)` captures the continuation as a closure. The CPS transform for `ctl` already handles this. The continuation includes all live variables at the `alloc` call site.

**Free variable analysis**: The free variable pass (Phase 3 in the LLVM roadmap) is needed before `ctl` allocators can compile to native code. The continuation closure captures heap-allocated variables; those captures must be resolved to explicit struct fields in the closure record.

### Allocator bootstrap problem

A `ctl` handler for `Alloc` itself needs memory to store the captured continuation. This creates a bootstrap dependency: the continuation closure uses the allocator being defined.

Resolution options:
1. **Fixed-size stack frames**: Continuations for `ctl alloc` handlers use a statically-sized frame, avoiding dynamic allocation. Feasible since `alloc` handler bodies are simple.
2. **Preallocated continuation pool**: The runtime preallocates a small pool for effect continuations before user-level handlers are installed.
3. **Separate system allocator**: CPS-generated closure records for effect handlers always use `malloc`/`free` directly, bypassing the user-level `Alloc` effect.

Option 3 is the simplest to implement and what Koka does internally. Start here.

---

## Implementation Sequence

This is a **Phase 4+** feature — after basic LLVM codegen is working.

### Prerequisites (from LLVM roadmap)

- Phase 1: Parser supports `effect` declarations (done)
- Phase 2: Type system supports effect rows and `with <E>` annotations
- Phase 3: CPS transform lowers effect operations to continuation calls
- Phase 4: Free variable analysis closes over captured variables
- Phase 5: LLVM codegen for closures and continuation records

### Memory model specific work

1. **Define `Alloc` as a built-in effect** in the effect system
2. **Implement ambient handler resolution**: when no `with` block installs a handler, resolve to a default `HeapAlloc` installed by the runtime startup
3. **Implement `<no Alloc>` constraint checking**: reject any allocation operation in functions annotated pure/no-alloc
4. **Provide standard handlers**: `HeapAlloc` (malloc/free), `ArenaAlloc` (bump with reset), `TrackingAlloc` (for debugging)
5. **Implement the bootstrap allocator**: a fixed malloc-based allocator for effect continuation records that cannot itself be intercepted

---

## Code Examples (Full)

### Switching allocators for a hot path

```cx
fn compute_intensive(): []float with <Alloc> {
    // ... allocates temporary buffers
}

fn main(): unit {
    with HeapAlloc {                    // default for most of the program
        setup();
        var result = with ArenaAlloc {  // hot path uses arena; reset on exit
            compute_intensive()
        };
        use_result(result);
        teardown();
    }
}
```

### Leak-checking allocator (for tests)

```cx
handler LeakCheck: Alloc {
    var count: int = 0;

    ctl alloc(size: int): ptr {
        count = count + 1;
        var p = malloc(size);
        resume(p);
        // runs after continuation
    }

    fn dealloc(p: ptr): unit {
        count = count - 1;
        free(p);
    }
}

fn test_no_leaks(): unit {
    var checker = LeakCheck { count: 0 };
    with checker {
        run_code_under_test();
    }
    assert(checker.count == 0, "memory leak detected");
}
```

### Allocation-free zone

```cx
fn interrupt_handler(): unit with <pure> {
    // compiler rejects any call to alloc() here
    read_sensor();
    set_flag();
}
```

---

## Prior Art

- **Koka** (Microsoft Research): heap effect in the type system; `alloc<h>` row variable tracks which heap a value lives in. Full formalization in the Koka papers.
- **Zig**: explicit allocator parameter threading. Proven in production; Cronyx improves ergonomics while preserving flexibility.
- **Haskell ST monad**: type-level heap regions via rank-2 types. Cronyx's effect rows achieve the same isolation without monadic boilerplate.
- **Rust**: `GlobalAlloc` trait swappable at link time only; per-scope allocator requires `Allocator` trait (nightly). Cronyx allows per-scope switching safely without unsafe.
