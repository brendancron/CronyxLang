/// Robustness regression tests — each test documents a case where the compiler
/// currently panics (ICE) instead of returning a proper error. The tests are
/// written to assert the *correct* post-fix behaviour; they will fail until the
/// corresponding fix is implemented.
///
/// Items tracked:
///   A — 1.2 Division by zero returns EvalError instead of panicking
///   B — 1.1 Oversized integer literal returns ScanError instead of panicking
///   C — 1.4 `for` over non-list returns EvalError instead of panicking
///   F — 1.3 Negative index out-of-bounds returns EvalError instead of silently wrapping
///   G — 2.2 Genuine arity errors caught by runtime type checker (not swallowed)
use std::io::Cursor;

use cronyx::frontend::lexer::tokenize;
use cronyx::runtime::interpreter::EvalError;
use cronyx::frontend::parser::{parse, ParseCtx};
use cronyx::runtime::environment::Environment;
use cronyx::runtime::interpreter::{eval, setup_modules};
use cronyx::semantics::cps::effect_marker::mark_cps;
use cronyx::semantics::cps::cps_transform::transform as cps_transform;
use cronyx::semantics::meta::interpreter_meta_evaluator::InterpreterMetaEvaluator;
use cronyx::semantics::meta::meta_processor::process;
use cronyx::semantics::meta::meta_stager::stage_all_files;
use cronyx::semantics::meta::staged_forest::StagedForest;
use cronyx::semantics::types::runtime_type_checker::type_check_runtime;
use cronyx::semantics::types::type_checker::type_check;
use cronyx::semantics::types::type_env::TypeEnv;
use cronyx::util::id_provider::IdProvider;

/// Run a Cronyx source snippet through the full interpreter pipeline.
/// Returns `Ok(stdout)` on success, `Err(message)` if any stage fails.
/// The function itself must not panic — panics are a test failure, not an Err.
fn run_source(src: &str) -> Result<String, String> {
    let tokens = tokenize(src).map_err(|e| format!("lex error: {e:?}"))?;
    let mut ctx = ParseCtx::new();
    parse(&tokens, &mut ctx).map_err(|e| format!("parse error: {e:?}"))?;
    let ast = ctx.ast;

    let type_env = type_check(&ast)
        .map(|(_, env)| env)
        .unwrap_or_else(|_| TypeEnv::new());

    let mut staged_forest = StagedForest::new();
    let mut id_provider = IdProvider::new();
    // single-file: no imports, so pass a one-element slice with a dummy FileRole
    use cronyx::frontend::module_loader::{FileRole, LoadedFile};
    let loaded = LoadedFile {
        path: std::path::PathBuf::from("<inline>"),
        source: src.to_string(),
        span_table: Default::default(),
        ast: ast.clone(),
        role: FileRole::Entry,
    };
    stage_all_files(&[loaded], &mut staged_forest, &mut id_provider, &type_env)
        .map_err(|e| format!("stage error: {e:?}"))?;
    staged_forest
        .resolve_symbol_deps()
        .map_err(|e| format!("dep error: {e:?}"))?;

    let module_bindings = staged_forest.module_bindings.clone();
    let mut eval_buf = Cursor::new(Vec::<u8>::new());
    let meta_env = Environment::new();

    let runtime_ast = {
        let mut evaluator = InterpreterMetaEvaluator {
            env: meta_env.clone(),
            type_env: TypeEnv::new(),
            out: &mut eval_buf,
            meta_captures: Vec::new(),
        };
        process(staged_forest, &mut evaluator).map_err(|e| format!("meta error: {:?}", e))?
    };

    let mut out_buf = Cursor::new(Vec::<u8>::new());
    let mut setup_env = cronyx::runtime::environment::EnvHandler::from(meta_env.clone());
    setup_modules(&runtime_ast, &module_bindings, &mut setup_env);

    eval(
        &runtime_ast,
        &runtime_ast.sem_root_stmts,
        meta_env,
        &mut out_buf,
        None,
        None,
    )
    .map_err(|e| format!("eval error: {e:?}"))?;

    Ok(String::from_utf8(out_buf.into_inner()).unwrap())
}

/// Run source through the full pipeline up to and including runtime type checking.
/// Returns `Ok(())` if type checking passes, `Err(message)` on any error.
fn check_types_runtime(src: &str) -> Result<(), String> {
    let tokens = tokenize(src).map_err(|e| format!("lex error: {e:?}"))?;
    let mut ctx = ParseCtx::new();
    parse(&tokens, &mut ctx).map_err(|e| format!("parse error: {e:?}"))?;
    let ast = ctx.ast;

    let type_env = type_check(&ast)
        .map(|(_, env)| env)
        .unwrap_or_else(|_| TypeEnv::new());

    let mut staged_forest = StagedForest::new();
    let mut id_provider = IdProvider::new();
    use cronyx::frontend::module_loader::{FileRole, LoadedFile};
    let loaded = LoadedFile {
        path: std::path::PathBuf::from("<inline>"),
        source: src.to_string(),
        span_table: Default::default(),
        ast: ast.clone(),
        role: FileRole::Entry,
    };
    stage_all_files(&[loaded], &mut staged_forest, &mut id_provider, &type_env)
        .map_err(|e| format!("stage error: {e:?}"))?;
    staged_forest
        .resolve_symbol_deps()
        .map_err(|e| format!("dep error: {e:?}"))?;

    let mut eval_buf = Cursor::new(Vec::<u8>::new());
    let meta_env = Environment::new();
    let runtime_ast = {
        let mut evaluator = InterpreterMetaEvaluator {
            env: meta_env.clone(),
            type_env: TypeEnv::new(),
            out: &mut eval_buf,
            meta_captures: Vec::new(),
        };
        process(staged_forest, &mut evaluator).map_err(|e| format!("meta error: {:?}", e))?
    };

    let cps_info = mark_cps(&runtime_ast);
    let runtime_ast = cps_transform(runtime_ast, &cps_info);

    let mut rt_env = TypeEnv::new();
    let mut warnings = Vec::new();
    type_check_runtime(&runtime_ast, &mut rt_env, &mut warnings)
        .map(|_| ())
        .map_err(|e| format!("type error: {e:?}"))
}

#[cfg(test)]
mod robustness_tests {
    use super::*;

    // ── A: Division by zero ───────────────────────────────────────────────────

    /// Dividing by a zero literal must return an EvalError, not panic.
    /// Currently panics in debug builds (Rust integer division by zero).
    /// Fix: add `if y == 0` guard in interpreter.rs returning EvalError::DivisionByZero.
    #[test]
    fn division_by_zero_returns_error() {
        let result = run_source("var _ = 10 / 0;");
        assert!(
            result.is_err(),
            "expected an error for division by zero, but got: {:?}",
            result
        );
    }

    /// Division by a runtime-computed zero must also return an error.
    #[test]
    fn division_by_runtime_zero_returns_error() {
        let result = run_source("var x = 0; var _ = 10 / x;");
        assert!(result.is_err(), "expected an error for division by zero, got: {:?}", result);
    }

    // ── B: Integer literal overflow ───────────────────────────────────────────

    /// An integer literal that overflows i64 must return a ScanError, not panic.
    /// Currently panics with `.unwrap()` on `parse::<i64>()` in lexer.rs.
    /// Fix: propagate `parse().map_err(ScanError::...)` instead of unwrapping.
    #[test]
    fn integer_overflow_returns_scan_error() {
        // 99999999999999999999 > i64::MAX (9223372036854775807)
        let result = tokenize("99999999999999999999");
        assert!(
            result.is_err(),
            "expected ScanError for oversized integer literal, but tokenize succeeded"
        );
    }

    // ── C: for-in over non-list ───────────────────────────────────────────────

    /// Iterating over an integer with `for (x in n)` must return an EvalError,
    /// not panic with the typo message "iterable expeced".
    /// Fix: replace the panic in value.rs:70 with proper EvalError propagation.
    #[test]
    fn for_in_non_list_returns_error() {
        let result = run_source("for (x in 42) { var _ = x; }");
        assert!(
            result.is_err(),
            "expected an error when iterating over a non-list, but got: {:?}",
            result
        );
    }

    /// Same for iterating over a string (also not a list).
    #[test]
    fn for_in_string_returns_error() {
        let result = run_source(r#"for (x in "hello") { var _ = x; }"#);
        assert!(
            result.is_err(),
            "expected an error when iterating over a string with for-in, got: {:?}",
            result
        );
    }

    // ── D: From<String> for EvalError ────────────────────────────────────────

    /// Arbitrary String errors converted via From<String> should become
    /// EvalError::Internal, not EvalError::UndefinedVariable.
    /// Fix: add EvalError::Internal(String) and update the From<String> impl.
    #[test]
    fn string_error_becomes_internal_not_undefined_variable() {
        let err: EvalError = EvalError::from("some internal error".to_string());
        assert!(
            matches!(err, EvalError::Internal(_)),
            "From<String> should produce Internal(_), not UndefinedVariable — got: {err:?}"
        );
    }

    // ── F: Negative index out of bounds ──────────────────────────────────────

    /// A negative index beyond the list length (e.g. xs[-5] on a 3-element list)
    /// must return an EvalError with a message that mentions the actual index (-5),
    /// not a huge wrapped usize. The current code casts a negative i64 to usize
    /// (UB in release builds) before the None path triggers the error.
    /// Fix: add `n >= -(len as i64)` guard before casting in interpreter.rs.
    #[test]
    fn negative_index_out_of_bounds_has_correct_message() {
        let result = run_source("var xs = [1, 2, 3]; var _ = xs[-5];");
        let err = result.expect_err("expected an error for out-of-bounds negative index");
        // The error message must reference -5, not a huge wrapped usize like 18446744073709551611
        assert!(
            err.contains("-5"),
            "error message should mention the actual index -5, but got: {err}"
        );
    }

    /// Boundary case: the most-negative valid index (-len) should still work.
    #[test]
    fn negative_index_at_boundary_succeeds() {
        // xs[-3] on a 3-element list is xs[0] — valid
        let result = run_source("var xs = [10, 20, 30]; print(to_string(xs[-3]));");
        assert_eq!(result.unwrap().trim(), "10");
    }

    // ── G: Arity swallowing in runtime type checker ───────────────────────────

    /// Calling a 1-arg function with 3 args must produce a TypeError, not silently succeed.
    /// Currently the type checker retries with trimmed args and discards the error.
    /// Fix: only retry when the extra arg is a CPS continuation lambda.
    #[test]
    fn extra_args_produce_type_error() {
        let result = check_types_runtime(
            "fn foo(x: int) -> int { return x; } var _ = foo(1, 2, 3);",
        );
        assert!(
            result.is_err(),
            "expected TypeError for extra arguments, but type checking succeeded"
        );
    }

    /// Correct arity must still type-check successfully (regression guard).
    #[test]
    fn correct_arity_type_checks_ok() {
        let result = check_types_runtime("fn foo(x: int) -> int { return x; } var _ = foo(1);");
        assert!(result.is_ok(), "correct arity should type-check: {result:?}");
    }
}
