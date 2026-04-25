# Cronyx Effect Type System

**Status:** Partially implemented — effect rows on `typeof`, unhandled-effect detection done; row unification and annotation enforcement are next.  
**Last Updated:** 2026-04-24  
**Depends on:** Cronyx Type System.md, EFFECTS_WITH_ROW_POLYMORPHISM.md

---

## Overview

Effect typing extends the existing Hindley-Milner type checker to track which algebraic effects a function may perform. The design uses **postfix effect rows on function types**: the effect row appears after the return type, keeping the base type clean and readable.

```
(int) -> int              // pure — no effects
(int) -> int <yield>      // performs yield
(int, int) -> unit <yield, log>   // performs yield and log
```

The row is a set of effect names. A function with an empty row (explicit `<>` or no annotation) is pure. Effects propagate upward through the call graph: if `range` performs `yield`, then any function that calls `range` also performs `yield` (unless a handler for `yield` is active).

---

## Surface Syntax

### Effect declarations

```cx
effect stream {
    ctl yield(i: int): unit;   // ctl — caller gains <yield>
}

effect io {
    fn log(msg: string): unit;  // fn — no effect row entry
    ctl emit(val: int): unit;   // ctl — caller gains <io>
}
```

`ctl` ops suspend the computation and require a handler. `fn` ops are transparent function replacements — they do not appear in the effect row.

### Run-handle blocks

```cx
run {
    range(0, 5, 1);
} handle stream {
    ctl yield(i) {
        print(i);
        resume;
    }
}
```

The handler block discharges `<yield>` from the row of the enclosed body.

### Function type annotations

Effect rows appear as a **postfix** on the return type:

```cx
fn range(low: int, high: int): unit <yield> {
    ...
}

fn logged_range(low: int, high: int): unit <yield, log> {
    ...
}

fn pure_fn(x: int): int {
    ...
}
```

### Effect row literal

```
<>                     // empty row (pure)
<yield>                // single effect
<yield, log>           // multiple effects (order irrelevant)
<yield | E>            // open row — "yield plus whatever E is"
```

---

## Internal Representation

### EffectRow

```rust
/// A closed effect row — the exact set of unhandled effects at a call site.
pub struct EffectRow {
    /// Named effects present in this row.
    pub effects: BTreeSet<String>,
    /// Optional row variable for open rows (row polymorphism).
    /// None = closed row (effects is the complete set).
    pub row_var: Option<TypeVar>,
}
```

`EffectRow::empty()` is `{ effects: {}, row_var: None }` — pure.

### Updated Type::Func

```rust
Type::Func {
    params: Vec<Type>,
    ret: Box<Type>,
    effects: EffectRow,   // NEW — empty by default
}
```

### Display

```
(int, int) -> unit          // empty row — display nothing
(int, int) -> unit <>       // explicit empty (only shown when ambiguous)
(int, int) -> unit <yield>  // one effect
(int, int) -> unit <yield, log>  // two effects (sorted alphabetically)
(a) -> b <yield | 'e>       // open row with row variable
```

---

## Effect Row Inference

### Rule 1 — Direct operation call

If a function body calls `op` where `op` is a `ctl` op of effect `E`, then the function has `E` in its effect row:

```cx
effect stream { ctl yield(i: int): unit; }

fn range(low: int, high: int): unit {
    yield(i);   // yield ∈ effect stream → range : (...) -> unit <yield>
}
```

### Rule 2 — Transitive call

If `f` calls `g` and `g : (...) -> T <E>`, then `f` gains `E`:

```cx
fn outer(): unit {
    range(0, 5, 1);  // range : (...) -> unit <yield>
                     // outer gains <yield> → outer : (...) -> unit <yield>
}
```

### Rule 3 — Handler discharge

A `run {} handle eff {}` block removes `eff`'s `ctl` ops from the required row of the enclosed body. The handler body itself is checked in the context where those ops are *not* active (they're being handled), but `resume` is available.

```cx
run {
    range(0, 5, 1);   // yield is discharged — no <yield> required here
} handle stream {
    ctl yield(i) { print(i); resume; }
}
```

Formally: if the enclosing scope requires row `R` and a handler for `stream` is active, the body only needs to satisfy `R \ {yield}`.

### Rule 4 — Polymorphic effect propagation

When a higher-order function takes a function argument, its effect row is parameterized over the argument's row:

```cx
fn map(f: (a) -> b <E>, xs: [a]): [b] <E>
```

`E` is a row variable. At each call site `E` is instantiated to the concrete row of the argument passed.

### Rule 5 — `fn` ops are transparent

`fn` ops in an effect declaration are not `ctl` — they don't suspend and don't require CPS. A function that only calls `fn` ops is pure from the effect row's perspective:

```cx
effect logger { fn log(msg: string): unit; }

fn greet(name: string) {
    log("Hello " + name);  // fn op — no effect row entry
}
// greet : (string) -> unit   (no <logger>)
```

---

## Unification

Effect row unification follows the same constraint-solving structure as type unification.

### Closed rows

Two closed rows unify iff their effect sets are equal:

```
<yield, log>  ~  <log, yield>    ✓ (sets are equal, order irrelevant)
<yield>       ~  <log>           ✗ TypeMismatch on effect rows
```

### Open rows

An open row `<yield | E>` unifies with `<yield, log>` by binding `E = <log>`. More generally:

```
<e1, ..., en | E>  ~  <e1, ..., en, f1, ..., fm>
    → E = <f1, ..., fm>
```

A row variable can unify with the empty row, making a function pure at a particular call site.

### Subrow (effect subsumption)

A function of type `(...) -> T <yield>` can be passed where `(...) -> T <yield, log>` is expected: it does fewer effects than required, which is safe. This is effect subsumption, analogous to subtyping.

Handled via open row unification: the `<yield>` row unifies with `<yield | E>` where `E` later gets resolved to `<log>` (or any superset).

---

## Handler Typing

### `fn` op handlers

A `fn` handler replaces the effect op with a plain function. It adds no effects to the surrounding context. Type-checked exactly like a function declaration.

```cx
run {
    log("hello");   // log : (string) -> unit — pure after handler installed
} handle logger {
    fn log(msg) { print(msg); }
}
```

### `ctl` op handlers

A `ctl op(params): ret` handler is checked against the declared signature of the op. Inside the handler body:

- The op's effect is **not** in scope (you're handling it, not calling it)
- `resume` has type `(ret) -> unit` (or `() -> unit` if `op` returns `unit`)
- The handler body may itself perform other effects, which propagate outward

```cx
effect ndet {
    ctl choose(options: [int]): int;
    ctl assert(cond: bool): unit;
}

run {
    var x = choose([1, 2, 3]);
    ...
} handle ndet {
    ctl choose(options) {
        // resume : (int) -> unit
        for (x in options) {
            resume x;   // each call resumes with a different value
        }
    }
    ctl assert(cond) {
        if (cond) { resume; }
    }
}
```

### Handler scope and nesting

Handlers nest. Inner handlers shadow outer ones. Effect discharge is scoped to the `run {}` block's lexical extent.

---

## Annotation Requirements

### Default: infer eagerly

Effect rows on function types are **inferred**, not required. If a function body calls a `ctl` op, the type checker adds the effect to its inferred row automatically. Annotations serve as constraints:

```cx
// Annotated — type checker verifies body matches
fn range(low: int, high: int): unit <yield> { ... }

// Unannotated — row inferred from body
fn range(low: int, high: int): unit { ... }
// → inferred as: (int, int) -> unit <yield>
```

### Annotation mismatch

If an annotation declares a *smaller* row than the body requires, it's a type error:

```cx
fn range(low: int, high: int): unit {   // annotated pure
    yield(i);                            // error: yield not in declared row
}
```

If an annotation declares a *larger* row than the body uses, it's allowed (conservative over-approximation is valid, though a warning may be appropriate in future).

---

## Effect Declarations and Op Types

Each op in an effect declaration has an implicit *effectful* type. `ctl` ops add the effect to the caller's row; `fn` ops do not (they're replaced, not suspended):

```cx
effect io {
    fn read_line(): string;           // fn — no effect propagation
    ctl write_line(s: string): unit;  // ctl — caller gains <io>
}
```

Op types are registered in the type environment when the `effect` declaration is processed.

---

## Implementation Status

| Feature | Status |
|---------|--------|
| Effect declarations parsed | ✅ Done |
| `run {} handle eff {}` syntax | ✅ Done |
| `typeof(f)` shows effect rows | ✅ Done |
| Unhandled ctl op → compile error | ✅ Done |
| Transitive effect propagation in `typeof` | ✅ Done |
| `fn` ops excluded from effect row | ✅ Done |
| Effect row unification in type checker | Planned |
| Annotation enforcement (`fn f(): T <yield>`) | Planned |
| Row polymorphism (`<E>` variables) | Planned |

---

## Error Cases

| Situation | Error |
|---|---|
| Calling an unhandled `ctl` op at top level | `UnhandledEffect { op: "yield" }` |
| Function annotation declares pure but body performs effects | `EffectRowMismatch { declared: <>, inferred: <yield> }` |
| Passing `f: (...) -> T <yield>` where `(...) -> T <>` expected | `EffectRowMismatch` |
| `resume` used outside a `ctl` handler body | `ResumeOutsideHandler` |
| Handler body's effects escape the handler scope | propagated to enclosing row (correct, not an error) |

---

## Open Questions

1. **Effect aliases:** Should `effect ndet { ... }` create a named alias usable in rows as `<ndet>` rather than listing `<choose, assert>` individually? Probably yes — ergonomics matter.

2. **`resume` type when `ctl op` returns non-unit:** If `ctl choose(options): int`, then `resume x` passes `x: int` back as the value of the `choose(...)` call. `resume` inside the handler has type `(int) -> unit`. Need to track this cleanly in the handler env.

3. **Row polymorphism in user-written annotations:** How far to go? At minimum, infer row variables internally. Whether users can write `<E>` as a named row variable in source is a separate ergonomics decision.

4. **Top-level effect requirement:** Should unhandled effects at the program entry point be a hard error, or a warning? (Koka requires handled; could start as warning.)
