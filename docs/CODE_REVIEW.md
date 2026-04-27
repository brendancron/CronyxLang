# Cronyx Compiler — Code Review

**Date:** 2026-04-25  
**Scope:** Full `rust_comp/src/` codebase  
**Verdict:** Solid skeleton with real technical debt. The core pipeline works, but there are correctness bugs, ~180 panic sites, architectural patterns that will cause maintenance pain, and at least two known-broken things that are silently tolerated.

---

## 1. Crashes on Valid (or Invalid) Input

These are places where the compiler will `panic!` rather than report a proper error. Every one of them is an ICE (Internal Compiler Error) waiting to happen in production.

### 1.1 Integer overflow on large literals — `lexer.rs:29`

```rust
(acc.parse::<i64>().unwrap(), i)
```

Any integer literal that doesn't fit in `i64` panics the lexer. The user gets no line number, no message — just a Rust panic. Should return `ScanError`.

### 1.2 Division by zero — `interpreter.rs:159`

```rust
(Value::Int(x), Value::Int(y)) => Ok(Value::Int(x / y)),
```

No zero check. In debug builds Rust panics on integer division by zero. In release builds it's undefined behavior (wraps to `i64::MIN` or similar on some platforms, panic on others). Needs an explicit `if y == 0` check returning `EvalError::DivisionByZero`.

### 1.3 Negative index wraps silently — `interpreter.rs:241, 247`

```rust
let i = if n < 0 { (len + n) as usize } else { n as usize };
```

When `n < -len`, `len + n` is negative. Casting a negative `i64` to `usize` wraps to a huge value (2^64 - |n|). Then `borrowed.get(i)` returns `None`, which surfaces as `"index -5 out of bounds"` — misleading because the printed value is the original negative index, but the actual index attempted was a very large `usize`. Needs a `n >= -len` guard before the cast.

### 1.4 `value.rs:70` — `enumerate()` panics with a typo

```rust
_ => panic!("iterable expeced"),  // sic
```

Called from the interpreter's foreach loop. Any non-list value here crashes the process instead of raising `EvalError`. The typo ("expeced") will appear in crash reports.

### 1.5 `parser.rs:332, 489` — two guaranteed panics

```rust
// Line 332
.expect("internal error: consume_next out of bounds")

// Line 489
panic!("parser made no progress in comma-separated list");
```

Line 332: `consume_next` is called after the parser has already verified the position, but if that assumption ever breaks, it panics. Should return `ParseError`.

Line 489: the infinite-loop guard in `parse_separated` panics instead of returning `ParseError::UnexpectedToken`. If any `parse_item` closure makes no progress, the user gets an ICE with no location information.

### 1.6 `main.rs:60` — panics if Entry file not found

```rust
let entry = files.iter().find(|f| matches!(f.role, FileRole::Entry)).unwrap();
```

`load_compilation_unit` returns the files it loaded, but there's no guarantee that at least one has `FileRole::Entry`. If the loader returns an empty vec or something changes, this panics. Use `.ok_or_else(|| ...)` and propagate.

### 1.7 `interpreter.rs:713` — I/O panic

```rust
writeln!(ctx.out, "{}", value).unwrap();
```

If stdout is closed (pipe broken, redirected to `/dev/full`, etc.) this panics the interpreter mid-execution. Should return `EvalError::IoError`.

### 1.8 `meta_processor.rs:93, 146` — unwrap on HashMap lookup

```rust
let staged_ast = staged_forest.ast_map.get(&tree_id).unwrap();
```

`tree_id` comes from the dependency queue. If there is any inconsistency between the queue and the map (bug in `resolve_symbol_deps`, cycle-detection gap, etc.) this panics. Propagate as `MetaError`.

### 1.9 `type_subst.rs:99, 113` — unwrap inside unification

```rust
let tb = fb.get(k).unwrap();
```

Unification over record types assumes both sides have the same field keys. If they don't (a bug in an earlier pass that constructed mismatched records), this panics inside the type checker rather than producing a type error.

---

## 2. Correctness Bugs

### 2.1 Phase 1 type checker accepts undefined variables — `type_checker.rs:222`

```rust
MetaExpr::Variable(name) => {
    env.lookup(&name).unwrap_or_else(|| Type::Var(env.fresh()))
}
```

An undefined variable gets a fresh type variable instead of an error. This means undefined variables pass Phase 1 undetected and only fail at Phase 2 (runtime type checker) — after the full meta-processing pipeline has run. You get a confusing error at the wrong stage for a basic mistake. Phase 1 should reject undefined variables unless this is intentional for staged code, in which case the intent needs documentation.

### 2.2 Arity errors swallowed in runtime type checker — `runtime_type_checker.rs:295-304`

```rust
// TODO(B2): Make this stricter. Currently swallows genuine arity
// errors too.
if unify(&callee_ty, &expected_fn, subst).is_err() && arg_types.len() > 1 {
    let trimmed = Type::Func {
        params: arg_types[..arg_types.len() - 1].to_vec(),
        ...
    };
    let _ = unify(&callee_ty, &trimmed, subst);
}
```

When unification fails, the type checker silently strips the last argument and retries. The stated reason is handling CPS-appended `__k` args, but the fix indiscriminately drops the last argument of ANY failing call, including genuine arity mismatches from user code. A user who calls `foo(a, b, c)` where `foo` only takes two arguments gets no error — the extra argument is silently discarded at the type level. This is a real correctness hole.

### 2.3 Effect marker transitive closure iterates hash maps in nondeterministic order — `effect_marker.rs:46-59`

```rust
loop {
    let mut added = false;
    for (name, &body_id) in &fn_bodies {
        if info.cps_fns.contains(name) { continue; }
        if body_calls_any_of(ast, body_id, &info.cps_fns) {
            info.cps_fns.insert(name.clone());
            added = true;
        }
    }
    if !added { break; }
}
```

`fn_bodies` is a `HashMap`. Each iteration of the outer loop visits functions in an arbitrary order and may mark some but not others, then re-runs. This is algorithmically correct (it will converge) but the number of iterations is O(n²) worst-case and the marking order is nondeterministic across runs. Use a worklist (queue of functions to process) seeded from the initial CPS set. This would be O(n) instead.

### 2.4 Named functions use dynamic scoping, lambdas use lexical — `value.rs:63`

```rust
pub struct Function {
    pub is_closure: bool,
    // True for `fn() { ... }` lambda — call uses lexical scoping.
    // False for named `fn foo()` — call uses dynamic scoping.
}
```

This means a named function defined inside another function uses the environment *at call time*, not at definition time. Capturing a variable from an outer function by defining an inner named function does not work the way users expect from any modern language. Contrast: a lambda `fn() { x }` captures `x` from its definition scope, but `fn helper() { x }` in the same context will fail or grab a different `x` depending on who calls `helper`. This is a user-visible semantic footgun. There should be one scoping rule.

---

## 3. Known Bugs Left Open (TODOs That Are Real Problems)

### 3.1 Polymorphic function warning goes to stderr — `runtime_type_checker.rs:86-90`

```rust
eprintln!(
    "warning: polymorphic call to `{callee}` with multiple distinct \
     concrete argument types — codegen will use the first call site. \
     Proper monomorphization is not yet implemented."
);
```

This warning is invisible in any CI environment, any IDE integration, any test that captures stdout, or any usage of `--dump-*` flags. It is a silent correctness problem: the user's polymorphic function will silently be compiled with wrong types. This needs to be a proper `CompilerError::Warning` (or at minimum written through the compiler's diagnostic path) and should block compilation until monomorphization is implemented.

### 3.2 `From<String> for EvalError` is wrong — `interpreter.rs:50-54`

```rust
// TODO this is not the correct way to do this
impl From<String> for EvalError {
    fn from(name: String) -> Self {
        EvalError::UndefinedVariable(name)
    }
}
```

Any arbitrary string error gets classified as `UndefinedVariable`. Code that does `some_fn()?` where `some_fn` returns `Result<_, String>` will surface completely unrelated errors (type errors, IO errors, etc.) as "undefined variable: <the error message>". Users will be confused. Either add a proper `EvalError::Internal(String)` variant or add proper error types for each case. The TODO has been there long enough to be a design decision that needs resolving.

---

## 4. Architecture Problems

### 4.1 Two-phase type checking over two ASTs with shared ID space

Phase 1 runs on `MetaAst` (usize IDs). Phase 2 runs on `RuntimeAst` (also usize IDs). IDs are reused across the two ASTs — a `stmt_id` from `MetaAst` and the same integer as a `stmt_id` in `RuntimeAst` refer to completely different nodes. The `IdProvider` hands out globally unique IDs within a compilation, which prevents collisions in practice, but there is no type-level distinction between a `MetaAst` ID and a `RuntimeAst` ID. A function accepting `usize` for one AST can silently accept an ID from the other. Newtypes (`MetaNodeId(usize)`, `RuntimeNodeId(usize)`) would catch this at compile time.

### 4.2 CPS transform mutates AST in-place with no rollback

`cps_transform.rs` takes `&mut RuntimeAst` and modifies it permanently. If the transform panics or an internal invariant is violated partway through, the AST is partially transformed — some functions have `__k` parameters, some don't — and subsequent passes will produce garbage or panic. The transform should either:
- Build a new AST (full immutability), or
- At minimum, validate all preconditions before starting any mutations.

### 4.3 Inconsistent error-collection strategy across pipeline stages

| Stage | Strategy |
|---|---|
| Load | Stop on first error |
| Type check (Phase 1) | Collect all errors |
| Meta processing | Stop on first error |
| Runtime type check | Collect all errors |
| Interpreter | Stop on first error |

This isn't wrong per se, but it's inconsistent and the cut points are not documented. The user experience is that sometimes they get one error, sometimes multiple, seemingly at random. Pick one strategy (collect all where possible) and apply it uniformly, or document why each stage deviates.

### 4.4 `Module` value is silently immutable — `value.rs:51`

```rust
Module(Rc<HashMap<String, Value>>),
```

All other mutable collection values (`Struct`, `List`) are wrapped in `Rc<RefCell<...>>`. `Module` is not. Any attempt to assign into a module field at runtime silently does nothing (no error, no panic — the assignment goes into the `Environment`, not the module). Compare `Struct`:

```rust
Struct {
    fields: Rc<RefCell<Vec<(String, Value)>>>,
}
```

Either wrap `Module`'s map in `RefCell` for consistency, or explicitly disallow module mutation and enforce that at the type-checker level.

### 4.5 `process_tree` is dead code — `meta_processor.rs:141-149`

```rust
pub fn process_tree<E: MetaEvaluator>(
    staged_forest: StagedForest,
    _evaluator: &mut E,  // note: unused
    tree_id: usize,
) -> Result<RuntimeAst, AstConversionError> {
```

The evaluator is accepted but prefixed with `_` and not used. This function is never called from `main.rs`. It's either dead code that should be deleted, or a partially-implemented path that was abandoned. Dead code in a compiler's core pipeline is a maintenance hazard.

---

## 5. Error Reporting Gaps

### 5.1 No source location on many runtime errors

`EvalError` variants carry the error kind but not the location (file, line, column) where the error occurred. When a runtime error happens deep in an evaluated expression, the user gets `"TypeError: expected int"` with no indication of where in their source file the problem is. The AST has node IDs, and `span_table` maps IDs to source spans — threading the failing node ID through `EvalError` would allow diagnostic enrichment at the surface.

### 5.2 Effect cycle detection is incomplete — `meta_processor.rs:119-123`

```rust
let processed_count = degree_map.values().filter(|&&d| d == 0).count();
if processed_count < staged_forest.ast_map.len() {
    return Err(String::from("Circular dependency detected between trees").into());
}
```

This detects that *some* trees weren't processed but gives no information about which trees form the cycle, what their names are, or what the dependency chain looks like. The error is also a raw `String` converted through a trait impl, losing all structure. The user gets: `"Circular dependency detected between trees"` — useless for debugging.

### 5.3 `args.rs` uses `eprintln!` for errors

```rust
eprintln!("unknown flag: {flag}");
eprintln!("run `cronyxc --help` for usage");
```

CLI argument errors write directly to stderr and don't go through the diagnostic system. They produce no consistent format, no exit code differentiation. They should use the same `Diagnostic::emit()` path as compiler errors.

---

## 6. Performance Issues

### 6.1 String indexing allocates on every access — `interpreter.rs:244-249`

```rust
let chars: Vec<char> = s.chars().collect();
let len = chars.len() as i64;
let i = if n < 0 { (len + n) as usize } else { n as usize };
chars.get(i).map(|c| Value::String(c.to_string()))
```

Every string index access allocates a `Vec<char>`, does one lookup, then discards the vector. For programs that index strings in a loop this is O(n) allocations per iteration. Either operate on byte offsets with UTF-8 awareness, or cache the char vec on the `Value::String` variant.

### 6.2 `stmt.clone()` inside type checker traversal — `type_checker.rs:49`

The type checker clones every statement before pattern-matching on it. The AST nodes can be large (`FnDecl` with params, body, type_params). This is O(n) unnecessary work. Pattern-match on a reference, and only clone the fields you need.

### 6.3 CPS suffix cloned for every ctl call — `cps_transform.rs:219-220`

```rust
let suffix = stmts[i + 1..].to_vec();
let suffix_transformed = self.transform_stmts(ast, suffix, is_cps_body);
```

For each CPS call in a statement list, the entire remaining suffix is collected into a new `Vec` and recursively transformed. For a function with `k` sequential CPS calls, the suffix is cloned and traversed `k` times. This is O(k²) transformations. It returns early after the first CPS call so in practice only one pass happens per call — but the structure is easy to misread and the suffix `Vec` allocation is unnecessary since you already have the slice. Pass `&stmts[i+1..]` directly.

### 6.4 `has_hof_fns` scans all expressions — `codegen/mod.rs:206-208`

```rust
let has_hof_fns = ast.exprs.values().any(|e| {
    matches!(e, RuntimeExpr::Variable(n) if fn_decl_name_set.contains(n))
});
```

This scans every expression in the entire program to detect higher-order function use. This should be a flag set during parsing or type checking, not a full re-scan at codegen time. For large programs this is a linear scan per compilation.

---

## 7. Code Quality and Maintainability

### 7.1 `expect_str()` / `expect_int()` panic on wrong token type

In `token.rs`, `expect_str()` and `expect_int()` are called at 20+ sites in the parser after a `consume()` that already verified the token type. If there's ever a mismatch (parser bug, token array corruption), you get a panic with no source location. These should return `Result` and the parser should propagate errors via `?`.

### 7.2 `parser.rs:195, 207, 282, 367, 397, 430` — direct `expect_str()` without error propagation

Several sites call `.expect_str()` on a token that was looked up by index without going through `consume()`. If the position is wrong, these panic. They should use `consume(tokens, pos, expected_type)?.expect_str()` with `?` propagation.

### 7.3 `type_checker.rs` misses effect collection for lambda bodies

`collect_body_effects` skips `FnDecl`, `WithFn`, and `WithCtl` bodies intentionally (documented), but it also skips `Lambda` bodies implicitly (falls through `_ => {}`). An effect produced inside a lambda literal will not be attributed to the enclosing function's effect row. This may or may not be intentional but is undocumented, and the fallthrough `_ => {}` is a silent catch-all that will absorb future statement kinds.

### 7.4 The interpreter comment in `main.rs` is stale — `main.rs:111-115`

```rust
// Both paths use full loop conversion now. The interpreter's old replay-stack
// mechanism handled ctl ops in while loops without loop-to-recursion conversion,
// but that approach cannot capture suspended continuations for async scheduling.
// The stack-depth concern for large loops is a known limitation of the interpreter.
cps_transform(&mut runtime_ast, &cps_info);
```

The comment acknowledges that stack-depth blowup is a "known limitation." That's a compiler correctness problem, not a limitation. A Cronyx program with a loop that performs 10,000 iterations and uses an effect will overflow the Rust call stack in the interpreter. This should be tracked as a bug, not a footnote in a code comment.

### 7.5 `debug_sink.rs` uses `unwrap()` for all file writes

```rust
writeln!(self.open(dir, "meta_ast_graph.txt"), "{ast:?}").unwrap();
```

If debug output fails (disk full, permissions), the compiler panics mid-compilation. Debug output failures should be non-fatal warnings, not ICEs.

### 7.6 `IdProvider::starting_from(max_id + 1)` in CPS transform is fragile — `cps_transform.rs:45-48`

```rust
let max_id = ast.stmts.keys().chain(ast.exprs.keys()).copied().max().unwrap_or(0);
let mut t = CpsTransform {
    ids: IdProvider::starting_from(max_id + 1),
    ...
};
```

This scans the AST once for the max ID, then hands out IDs starting from `max_id + 1`. This is correct as long as no other code adds nodes to the AST between the scan and the transform. Currently nothing does, but this implicit ordering constraint is not enforced. If any pass is ever inserted between `mark_cps` and `cps_transform`, it will silently corrupt IDs.

---

## 8. Summary Table

| Severity | Count | Category |
|---|---|---|
| P0 — will crash on user input | 3 | Integer overflow, division by zero, negative index |
| P0 — will crash on internal inconsistency | 6 | Unwraps in parser, meta-processor, type-subst |
| P1 — silently wrong output | 2 | Arity swallowing in type checker, polymorphic call warning |
| P1 — user-visible semantic bug | 1 | Named functions use dynamic scoping |
| P2 — poor error messages / silent failures | 5 | No location on runtime errors, cycle detection message, `From<String>` misclassification |
| P2 — architectural debt | 5 | No ID newtypes, mutable AST transforms, Module immutability, dead code |
| P3 — performance | 4 | String index alloc, HOF scan at codegen, type checker clones, CPS suffix |

**Highest-leverage fixes in order:**
1. Divide-by-zero and integer overflow — five lines each, obvious fix, high blast radius.
2. Arity swallowing in `runtime_type_checker.rs:298-304` — remove the retry-with-trimmed-args hack; it masks real bugs.
3. `From<String> for EvalError` → add `EvalError::Internal(String)`.
4. `value.rs:70` enumerate panic + typo — five-line fix.
5. ID newtypes for `MetaNodeId` / `RuntimeNodeId` — this prevents a whole class of future mistakes.
