# Handler Struct & Closure Passing — Spec

## Goal

Replace dynamic `with_fn_active` dispatch with explicit handler structs passed as function
parameters. Unifies `fn` and `ctl` effect semantics, eliminates the interpreter/compiler
divergence, and enables cross-function effect dispatch in compiled code.

---

## Handler Struct Shape

Each `effect` declaration implicitly defines a handler struct type. The compiler synthesises
it — users never write it explicitly.

### `fn` operations

```cx
effect log {
    fn log(msg: string): unit;
}
// Synthesised:
// __LogHandler = { log: (string) -> unit }
```

The field type matches the operation signature exactly.

### `ctl` operations

```cx
effect flip {
    ctl flip(): bool;
}
// Synthesised:
// __FlipHandler = { flip: ((bool) -> unit) -> unit }
```

The field takes one extra argument: the continuation `(ret_type) -> unit`. The handler body
calls `resume` which invokes this continuation.

### Mixed effects

```cx
effect logic {
    ctl choose(options): int;
    ctl guard(cond: bool): unit;
}
// Synthesised:
// __LogicHandler = {
//     choose: ([int], (int)  -> unit) -> unit,
//     guard:  (bool, (unit) -> unit) -> unit,
// }
```

---

## Function Signature Transformation

Any function that uses a `fn` or `ctl` effect operation (directly or transitively) receives
one extra parameter per distinct effect it uses, appended to its parameter list.

Naming: `__h_{EffectName}` — e.g. `__h_log`, `__h_flip`, `__h_logic`.

```cx
// Before
fn greet(name: string): unit {
    log("Hello, " + name);
}

// After
fn greet(name: string, __h_log): unit {
    var log = __h_log.log;   // injected binding
    log("Hello, " + name);   // call unchanged
}
```

The injected `var log = __h_log.log` rebinds the operation name to the field value.
Existing call sites for `log(...)` require no further rewriting — they resolve to the local.

Multi-effect functions get one param per effect, in declaration order:

```cx
fn compute(x): int {
    log("computing");
    var n = ask();
    return x + n;
}
// becomes:
fn compute(x, __h_log, __h_ask): int {
    var log = __h_log.log;
    var ask = __h_ask.ask;
    log("computing");
    var n = ask();
    return x + n;
}
```

---

## Handler Instantiation

A `handle` clause becomes a struct literal constructed inline. The struct's type name is the
synthesised handler type for the effect.

```cx
// Before
run {
    greet("Brendan");
} handle log {
    fn log(msg: string) { print(msg); }
}

// After
var __h_log_0 = __LogHandler { log: fn(msg) { print(msg); } };
greet("Brendan", __h_log_0);
```

The `run { } handle { }` wrapping disappears entirely — it becomes a struct construction
followed by ordinary function calls that pass the struct.

---

## Named Handlers (Problem C)

`handler name: effect { ... }` is just a variable binding of the synthesised handler type:

```cx
// Before
handler logic_handler: logic {
    ctl choose(options): int { for (x in options) { resume x; } }
    ctl guard(cond: bool): unit { if (cond) { resume; } }
}
run { ... } with logic_handler;

// After
var logic_handler = __LogicHandler {
    choose: fn(options, __k) { for (x in options) { __k(x); } },
    guard:  fn(cond, __k)    { if (cond) { __k(unit); } },
};
// run { } with logic_handler  → pass logic_handler to body fn
(fn(__h_logic) { ... })(logic_handler);
```

No special runtime support needed for named handlers — they are ordinary values.

---

## What Changes in Each Layer

### 1. `effect_marker.rs` / new `FnEffectInfo`

Add a parallel analysis for `fn` effects:

```rust
pub struct FnEffectInfo {
    /// effect name → list of fn-op names it declares
    pub fn_ops: HashMap<String, Vec<String>>,
    /// function name → set of effect names it uses (directly or transitively)
    pub fn_effect_fns: HashMap<String, HashSet<String>>,
}
```

Phases:
1. Collect `fn` ops from `EffectDecl` statements into `fn_ops`.
2. Find functions that call those ops directly.
3. Transitive closure (same BFS as `mark_cps`).

### 2. New pass: `handler_transform.rs`

Runs **after** `cps_transform`, before runtime type checking. Rewrites the RuntimeAst:

- For each function in `fn_effect_fns`: add handler params, inject field bindings at top of body.
- For each `WithFn` / `run..handle fn` site: synthesise struct literal, rewrite callers.
- For each named `handler` declaration: rewrite to `VarDecl` of struct literal.
- For each `run { } with name` site: pass the named handler var as argument.

### 3. `runtime_ast.rs`

No new AST nodes required. The transform produces only existing node kinds:
- `VarDecl` for injected bindings and handler construction
- `StructLiteral` for handler structs (type name = `__XxxHandler`)
- Existing `Lambda` for handler function fields
- Existing `Call` for rewritten call sites (callee name now resolves to local binding)

Handler struct types are anonymous — they don't appear in `StructDecl`. The type checker
infers them structurally.

### 4. Interpreter (`interpreter.rs`)

Remove `fn_handlers` stack and the `fn_handlers` fallback in Variable lookup.
`WithFn` no longer needs special handling in `eval_stmts` — it's been transformed away.
The struct-passing path falls through naturally via `Value::Struct` + `DotAccess`.

### 5. Codegen (`codegen/mod.rs`)

Remove `with_fn_active` map lookup. Handler structs are emitted as regular LLVM structs
with closure-typed fields. `DotAccess` on a handler struct field returns a closure value,
which is then called via the existing indirect-call / HOF path.

---

## Implementation Phases

1. **(this session)** `FnEffectInfo` marker + `handler_transform.rs` for `fn` ops only
   → fixes log, ask, handler, delim, multi_handle
2. Extend to `ctl` ops in handler structs → fixes multi_guard (named handlers)
3. Fix CPS bug in recover (Problem B — separate from this pass)
4. Update interpreter to remove `fn_handlers` fallback
5. Update codegen to remove `with_fn_active` lookup
