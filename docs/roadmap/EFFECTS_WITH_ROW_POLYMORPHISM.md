# Cronyx Effects with Row Polymorphism & Selective CPS

## High-Level Vision

Instead of full CPS transform or threading hacks, use **row-polymorphic effect types** like Koka:
- Function types track which effects they can perform
- Type inference propagates effect info up the call chain
- Only functions that perform `ctl` effects get CPS-transformed
- Continuations are threaded as regular parameters only where needed

This solves the "flip.cx problem" (arbitrary call depth) cleanly without refactoring the whole codebase.

---

## Core Ideas

### 1. Effect Rows in Types

Functions declare their effect capability:

```
fn range(low: int, high: int): unit with <yield>
fn foo(): int with <log, yield>
fn pure_fn(): bool with <>
```

Type: `(int, int) -> unit / <yield>`  where `/ <yield>` is the effect row.

### 2. Effect Inference

If a function calls another function with effects, it inherits those effects:

```
fn map(f: (int) -> int, xs: list): list with <???> {
    for(x = xs) {
        f(x);    // f might have effects!
    }
}
```

Compiler infers: `map` has effects of whatever `f` has. Type becomes polymorphic: `(a) with E -> list with E`.

### 3. Selective CPS Transform

Only transform functions that:
1. **Perform a `ctl` operation directly**, OR
2. **Call a function with `ctl` effects**

A function with `fn` effects only (no `ctl`) doesn't get transformed.

### 4. Handler Passing as Implicit Parameters

When you call a function with effect requirement `with <yield>`, the active handler for `yield` is implicitly passed down.

```
with ctl yield(i: int): unit {
    print(i);
    resume
}

range(0, 5);  // compiler inserts: pass yield handler implicitly
```

---

## Example: How It Works

### Original Code (yield.cx)

```
effect yield { ctl yield(i: int): unit; }

fn range(low: int, high: int): unit {
    for(i = low; i < high; i++) {
        yield(i);
    }
}

with ctl yield(i: int): unit {
    print(i);
    resume
}

range(0, 5);
```

### After Type Inference

```
fn range(low: int, high: int): unit with <yield>  // <-- effect row added

with ctl yield(i: int): unit { ... }

range(0, 5);  // type checker verifies: yield is active
```

### After Selective CPS Transform

```
fn range(low: int, high: int, __handler_yield): unit {
    // __handler_yield = { op_name: "yield", params: [...], body: ..., resume_cont: ??? }
    for(i = low; i < high; i++) {
        __handler_yield.call(i, __resume_cont);
        // __resume_cont is the "loop body + rest"
    }
}

with ctl yield(i: int): unit { ... }

// Call site: compiler inserts handler as parameter
range(0, 5, active_handlers["yield"]);
```

### At Runtime

`yield(i)` doesn't suspend — it becomes a function call to the handler! The handler receives the continuation as a value.

---

## Architecture: What Changes

### Type System (New)

```rust
pub struct Type {
    // ... existing variants ...
    // But Function type changes:
    Func {
        params: Vec<Type>,
        ret: Box<Type>,
        effects: EffectRow,  // <-- NEW
    }
}

pub struct EffectRow {
    pub effects: BTreeSet<String>,  // {"yield", "log"}
}
```

### Parser (Minimal Change)

Allow effect annotations in function signatures:

```
fn foo(): int with <yield, log> { ... }
```

Parse into:
```rust
FnDecl {
    name: "foo",
    params: [...],
    effect_row: EffectRow { effects: {"yield", "log"} },  // <-- NEW
    body: ...,
}
```

### Type Checker (Major Addition)

1. **Effect inference:** Walk function bodies, collect operations performed
2. **Unification:** For polymorphic functions, infer effect rows from call sites
3. **Row polymorphism:** Support `fn map(f: (a) with E -> b): list with E`
4. **Validation:** Ensure operations called only when active

### Compiler Pass (New): Effect-Driven CPS Transform

Run **after** type checking, **before** interpretation:

```
fn transform_for_effects(ast: RuntimeAst) -> RuntimeAst {
    // 1. Find all functions with ctl effects in their rows
    for each fn with ctl in effects {
        // 2. Transform its body: add __handler params, transform calls, transform returns
        transform_fn_cps(fn);
        
        // 3. Find all callers of this fn
        for each caller {
            // 4. If caller doesn't have this effect, mark it for transformation too
            if caller doesn't have effect {
                caller.effects |= fn.effects;  // propagate
                mark_for_transform(caller);
            }
        }
    }
    
    // 5. Apply transformations (topologically)
    while marked_for_transform not empty {
        pick fn from marked_for_transform;
        transform_fn_cps(fn);
    }
}
```

### Interpreter (Minimal Change)

When calling a CPS-transformed function, pass handler as extra parameter. Handler is a regular value, so no special interpreter logic needed — it's just a function call.

---

## Detailed Design: Effect Inference

### Algorithm

1. **Pre-process:** Scan all function declarations, extract declared effect rows
2. **Infer:** Walk function bodies
   - Direct `ctl` op call? → add to effect set
   - Call to function with known effects? → add those effects
   - Polymorphic effect variable? → record as constraint
3. **Unify:** Solve constraints (like type inference)
4. **Propagate:** Re-infer until fixed point (recursive functions)

### Example

```
fn range(low: int, high: int): unit {   // declared: unit / <>
    for(i = low; i < high; i++) {
        yield(i);                         // ctl op found!
    }
}
```

Type checker:
1. Parses declared effect row: `<>` (empty)
2. Body infers effect row: `<yield>` (found `yield` call)
3. **Conflict!** Either:
   - Update fn to have `with <yield>` (require annotation), OR
   - Infer automatically (if annotations optional)

Decision: **Require annotations** (explicit is better, like type signatures). If fn body has `ctl` ops not in declared row → type error.

### Polymorphic Effects

```
fn map(f: (int) with E -> int, xs: list): list with E {
    for(x = xs) {
        f(x);  // effect row: E (from parameter type)
    }
}
```

Type system: `E` is an effect row variable. When `map` is called:
```
map(range, [1,2,3])  // range has effects <yield>
                     // So E = <yield>
                     // map's effects inferred: <yield>
```

---

## Implementation Phases

### Phase 0: Design & Type System (1-2 weeks)

- [ ] Design effect row representation
- [ ] Extend `Type` enum with effect rows
- [ ] Extend parser to accept `with <...>` annotations
- [ ] Basic type checker changes (store effect rows)
- [ ] Write tests: parsing + type checking effect annotations

No interpreter changes yet. Just make sure types work.

### Phase 1: Effect Inference (1 week)

- [ ] Implement effect inference algorithm
- [ ] Scan for `ctl` ops in function bodies
- [ ] Propagate effects through call chain
- [ ] Type check: ensure operations are in declared rows
- [ ] Tests: verify inference on simple + recursive functions

### Phase 2: CPS Transform Pass (2 weeks)

- [ ] Design: what does transformed AST look like?
- [ ] Implement selective transformation
- [ ] Transform function bodies: add handler params, transform calls, transform returns
- [ ] Handle `resume` in handler bodies (becomes `__k_cont(value)` call)
- [ ] Tests: verify transformed code is syntactically correct (don't run yet)

### Phase 3: Interpreter Integration (1 week)

- [ ] Update interpreter to handle CPS-transformed code
- [ ] Handler values in `Value` enum
- [ ] Pass handlers as function parameters
- [ ] Test: `yield.cx` passes
- [ ] Test: `flip.cx` passes

### Phase 4: `fn` Effects (1 week)

- [ ] Implement `fn` effect handlers (no CPS needed)
- [ ] Test: `log.cx` passes

---

## Files to Create/Modify

| File | What | Effort |
|---|---|---|
| `semantics/types/effect_row.rs` | NEW: `EffectRow`, row operations | Low |
| `semantics/types/types.rs` | MODIFY: `Type::Func` gets `effects` field | Medium |
| `frontend/meta_ast.rs` | MODIFY: `FnDecl` gets optional `effect_row` | Low |
| `frontend/parser.rs` | MODIFY: parse `with <...>` annotations | Medium |
| `semantics/types/type_checker.rs` | MODIFY: type check effect rows, infer effects | High |
| `semantics/meta/effect_inference.rs` | NEW: effect inference algorithm | High |
| `semantics/meta/cps_transform.rs` | NEW: selective CPS transformation | Very High |
| `runtime/interpreter.rs` | MODIFY: handle CPS-transformed code | Medium |
| `frontend/meta_ast.rs` | MODIFY: add `EffectOp`, `EffectDecl`, `WithFn`, `WithCtl`, `Resume` | Low |
| `runtime/value.rs` | MODIFY: add `Handler` value type | Low |

---

## Key Design Decisions

### Q: Explicit effect annotations or inferred?
**A:** Explicit. Require `fn foo(): int with <yield>` in function signature. Infer only for called functions (propagate up). Makes code clearer, type errors better.

### Q: What about `fn` effects?
**A:** Don't transform. `fn` effects are just function replacements, no continuation needed. `with fn log { ... }` → install function binding in scope.

### Q: What if a function is called with and without effects?
**A:** Type error. Function signature is fixed; can't call it in two different effect contexts. (Alternative: support overloading per effect row, but that's complex.)

### Q: How are handlers passed at call sites?
**A:** Implicitly by compiler. When calling `range(0, 5)` with active `yield` handler, compiler inserts it as an extra parameter automatically.

### Q: What about `resume` with a value?
**A:** In transformed code, `resume expr` becomes `__k_cont(expr)` — just call the continuation function with the value.

### Q: Multiple active handlers?
**A:** Handler stack. When calling a function with `with <yield, log>`, pass handler stack (or multiple params). Lookup by operation name.

---

## Why This Approach

✓ **Correct:** Handles `flip.cx` naturally (continuation as value)
✓ **Elegant:** Type-system-driven, Koka-style
✓ **Modular:** Only transform affected functions
✓ **Clear:** Effect rows make code intention explicit
✗ **Complex:** Requires effect inference + CPS transform
✗ **Time:** Weeks of work, not days

---

## Risks & Unknowns

1. **CPS transform correctness:** Need to carefully handle all statement types (loops, if, match, etc.)
2. **Effect row design:** What's the right representation? Rows vs sets vs lists?
3. **Polymorphic rows:** How far do we go? Full row polymorphism is complex.
4. **Error messages:** CPS-transformed code is hard to debug; need good source mapping.
5. **Performance:** Transformed code has extra function calls; might be slow.

---

## Alternative: Hybrid (Shorter Timeline)

If full row polymorphism is too much, consider:
- Skip effect inference; require all annotations (simpler type checker)
- Skip row polymorphism; effects are monomorphic (simpler type system)
- Implement CPS transform only for simple cases (functions that directly call `ctl` ops)

This reduces complexity by ~40%, still gives you clean semantics.
