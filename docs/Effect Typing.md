# Cronyx Effect Type System

**Status:** Design / Planning  
**Last Updated:** 2026-04-19  
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

### Function type annotations

Effect rows appear as a **postfix** on the return type in both source annotations and printed types:

```
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

### Handler scoping

`with ctl` blocks discharge an effect from the row. Inside a handled scope, callers of the effect op no longer need to declare it:

```
// Outside: code with <yield> in its row is not callable (yield unhandled)

with ctl yield(i: int): unit {
    print(i);
    resume;
}

// Inside: yield is handled — calling range() here is fine even though
// range : (int, int) -> unit <yield>
range(0, 10, 1);
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

If a function body calls `op` where `op` belongs to effect `E`, then the function has `E` in its effect row:

```
effect yield { ctl yield(i: int): unit; }

fn range(...): unit {
    yield(i);   // yield ∈ effect yield → range : (...) -> unit <yield>
}
```

### Rule 2 — Transitive call

If `f` calls `g` and `g : (...) -> T <E>`, then `f` gains `E`:

```
fn outer(...): unit {
    range(0, 5, 1);  // range : (...) -> unit <yield>
                     // outer gains <yield> → outer : (...) -> unit <yield>
}
```

### Rule 3 — Handler discharge

A `with ctl op` block removes `op` from the required row of the code that follows within its scope. The handler body itself is checked in the context where `op` is *not* active (it's being handled), but `resume` is available.

```
with ctl yield(i: int): unit {
    print(i);
    resume;
}
range(0, 5, 1);   // yield is discharged — no <yield> required here
```

Formally: if the enclosing scope requires row `R` and a `with ctl yield` handler is active, calls to `range` only need to satisfy `R \ {yield}`.

### Rule 4 — Polymorphic effect propagation

When a higher-order function takes a function argument, its effect row is parameterized over the argument's row:

```
fn map(f: (a) -> b <E>, xs: [a]): [b] <E>
```

`E` is a row variable. At each call site `E` is instantiated to the concrete row of the argument passed.

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

### `with fn` handlers

A `with fn` handler replaces the effect op with a plain function. It adds no effects to the surrounding context (it's just a function binding). Type-checked exactly like a function declaration.

```
with fn log(msg: string): unit {
    print(msg);   // print : (string) -> unit — no effects
}
// After: log : (string) -> unit  (no effect row — it's pure now)
```

### `with ctl` handlers

A `with ctl op(params): ret` handler is checked against the declared signature of `op`. Inside the handler body:

- `op`'s effect is **not** in scope (you're handling it, not calling it)
- `resume` has type `(ret) -> unit` (or `() -> unit` if `op` returns `unit`)
- The handler body may itself perform other effects, which propagate outward

```
effect ndet {
    ctl choose(options: [int]): int;
    ctl assert(cond: bool): unit;
}

with ctl choose(options: [int]): int {
    // resume : (int) -> unit
    for (x in options) {
        resume x;   // each call resumes with a different value
    }
}
// After: choose is handled — its effect is discharged in the scope below
```

### Handler scope and nesting

Handlers nest. Inner handlers shadow outer ones. Effect discharge is scoped to the `with` block's lexical extent:

```
with ctl yield(i: int): unit {
    print(i); resume;
}
// yield discharged here

// Some block with yield re-introduced...
fn needs_yield(): unit <yield> {
    yield(42);
}
// Calling needs_yield() outside the with block → type error (yield unhandled)
```

---

## Annotation Requirements

### Default: infer eagerly

Effect rows on function types are **inferred**, not required. If a function body calls a `ctl` op, the type checker adds the effect to its inferred row automatically. Annotations serve as constraints:

```
// Annotated — type checker verifies body matches
fn range(low: int, high: int): unit <yield> { ... }

// Unannotated — row inferred from body
fn range(low: int, high: int): unit { ... }
// → inferred as: (int, int) -> unit <yield>
```

### Annotation mismatch

If an annotation declares a *smaller* row than the body requires, it's a type error:

```
fn range(low: int, high: int): unit {   // annotated pure
    yield(i);                            // error: yield not in declared row
}
```

If an annotation declares a *larger* row than the body uses, it's allowed (conservatively over-approximating is valid, though a warning may be appropriate in future).

---

## Effect Declarations and Op Types

Each op in an effect declaration has an implicit *effectful* type. `ctl` ops add the effect to the caller's row; `fn` ops do not (they're replaced, not suspended):

```
effect io {
    fn read_line(): string;           // fn — no effect propagation
    ctl write_line(s: string): unit;  // ctl — caller gains <io>
}
```

Op types are registered in the type environment when the `effect` declaration is processed.

---

## Changes Required

### `rust_comp/src/semantics/types/types.rs`

- Add `EffectRow` struct (`BTreeSet<String>` + optional `TypeVar`)
- Add `effects: EffectRow` field to `Type::Func`
- Update `Display` impl to print effect row postfix
- Update unification (`type_subst.rs`, `type_utils.rs`) to handle row unification

### `rust_comp/src/semantics/types/type_env.rs`

- Track active handlers in a handler stack during inference
- `push_handler(effect_name)` / `pop_handler()` for `with ctl` scope
- `is_handled(name) -> bool` — for discharge rule

### `rust_comp/src/semantics/types/type_checker.rs` and `runtime_type_checker.rs`

- `infer_fn_body` accumulates effect set from calls and transitive calls
- `EffectDecl` registers op types with their row contributions
- `WithCtl` discharges effect from current scope, checks handler body with `resume` in env
- `WithFn` registers op as a plain function binding (no effect row)
- Validate explicit effect row annotations against inferred rows

### `rust_comp/src/frontend/parser.rs` (or meta_ast)

- Parse `): type <effect, ...>` in function declarations and lambda signatures
- Parse effect rows in explicit type annotations (e.g. `var f: (int) -> int <yield>`)
- The angle bracket postfix should parse as part of the return type, not a comparison

### `rust_comp/src/semantics/types/type_subst.rs`

- Extend substitution to include row variable substitutions alongside type variable substitutions
- `apply_subst` on `EffectRow` resolves row variables

### New: `rust_comp/src/semantics/types/effect_row.rs`

- `EffectRow` definition and operations: `empty`, `singleton`, `union`, `remove`, `contains`
- `unify_rows(r1, r2, subst) -> Result<Subst, TypeError>` — row unification
- `RowVar` aliased to `TypeVar` (same structure, different semantic role)

---

## Error Cases

| Situation | Error |
|---|---|
| Calling an unhandled `ctl` op at top level | `UnhandledEffect { op: "yield" }` |
| Function annotation declares pure but body performs effects | `EffectRowMismatch { declared: <>, inferred: <yield> }` |
| Passing `f: (...) -> T <yield>` where `(...) -> T <>` expected | `EffectRowMismatch` |
| `resume` used outside a `with ctl` handler body | `ResumeOutsideHandler` |
| Handler body's effects escape the handler scope | propagated to enclosing row (this is correct, not an error) |

---

## Open Questions

1. **Top-level effect requirement:** Should unhandled effects at the program entry point be a hard error, or a warning? (Koka requires handled; could start as warning.)

2. **`fn` ops and effect rows:** Do `fn` ops add anything to the caller's row? Current thinking: no — they're transparent replacements. But if the handler itself has effects, those propagate. Need to decide if that's tracked on the op type.

3. **Effect aliases:** Should `effect ndet { ... }` create a named alias usable in rows as `<ndet>` rather than listing `<choose, assert>` individually? Probably yes — ergonomics matter.

4. **`resume` type when `ctl op` returns non-unit:** If `ctl choose(options): int`, then `resume x` passes `x: int` back as the value of the `choose(...)` call. `resume` inside the handler has type `(int) -> unit`. Need to track this cleanly in the handler env.

5. **Row polymorphism in user-written annotations:** How far to go? At minimum, infer row variables internally. Whether users can write `<E>` as a named row variable in source is a separate ergonomics decision.
