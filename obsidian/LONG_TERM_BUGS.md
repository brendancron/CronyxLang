# Long-Term Bugs & Technical Debt

## Deferred Features

### T1 — Multi-handle integration test

Add a script integration test for `run {} handle eff1 {} handle eff2 {}` where both effects are `ctl` ops and are active simultaneously. The multi_handle test that exists (`tests/effects/multi_handle`) uses one fn and one ctl effect; a test with two simultaneous ctl effects would give stronger coverage.

### T2 — Port unhandled-effect error tests

`tests/effects/unhandled_direct/`, `unhandled_transitive/`, and `unhandled_hof/` test that calling an unhandled `ctl` op is a compile error. These use effects2-compatible syntax and were passing in `compile_all_integration` before the effects1 cleanup. Port them to `tests/effects/` with a matching `run_err_test` harness entry once the interpreter error test infrastructure supports them cleanly.

---

Known issues deferred for future work. Not blocking release.

---

## B1 — CPS arity checking swallowed in runtime type checker

**File:** `rust_comp/src/semantics/types/runtime_type_checker.rs:298`

**Description:** When type-checking a function call in the CPS-transformed AST, if the argument count doesn't match the declared parameter count, the type checker currently strips the last argument and retries rather than emitting an error. This handles the `__k` continuation parameter that CPS appends to every effectful call, but it also silently swallows genuine arity errors.

**Root cause:** Phase 2 type checking runs on the AST after CPS transformation. CPS-transformed calls have one extra argument (`__k`) not present in the original function declaration. A single code path handles both pre-CPS and post-CPS ASTs, so there's no way to distinguish "extra arg is the CPS continuation" from "extra arg is a user bug."

**Proper fix:** Thread `CpsInfo` (which functions were transformed, which params are CPS-appended) into `infer_expr` so the arity check can skip `__k` args specifically rather than dropping the last arg blindly.

**Workaround:** Existing tests provide coverage. Real arity errors still surface at runtime as argument mismatches.

---

## B2 — `From<String> for EvalError` conflates missing variables with other string errors

**File:** `rust_comp/src/runtime/interpreter.rs:51`

**Description:** The `From<String>` impl on `EvalError` converts any `String` into `EvalError::UndefinedVariable`. This is used as a shortcut for environment lookups that return `Err(name)` when a variable isn't found. The problem is that any other code path that returns `Err(String)` — even accidentally — would be misclassified as an undefined variable error rather than the actual error.

**Root cause:** Quick hack to propagate env lookup failures without threading a proper error type through the environment API.

**Proper fix:** Give `Environment::get` a dedicated error type (e.g. `EnvError::NotFound(String)`). Remove the `From<String>` impl and update all callers to map errors explicitly.

**Workaround:** In practice, only env lookups return `Err(String)` today, so misclassification doesn't occur.
