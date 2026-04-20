# Cronyx Compiler Error Handling

**Status:** Planning  
**Last Updated:** 2026-04-20  
**Owner:** Brendan

---

## Problem

Every pipeline stage currently uses `.unwrap()`. Any error produces a Rust panic with an internal `Debug` representation:

```
thread 'main' (161560) panicked at src/main.rs:58:48:
called `Result::unwrap()` on an `Err` value: TypeCheckFailed(UnboundVar("name"))
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

This is unacceptable for a compiler. Users should see:

```
error[E0012]: unbound variable 'name'
  --> scratch/errors/main.cx:5:8
   |
 5 | var x = name + 1;
   |         ^^^^ not found in this scope
```

---

## Current Error Landscape

### Pipeline stages and their error types

| Stage | File | Error Type |
|---|---|---|
| Load / Parse | `frontend/module_loader.rs` | `LoadError { Io, Parse }` |
| Type check (pass 1) | `semantics/types/type_checker.rs` | `TypeError` |
| Meta staging | `semantics/meta/meta_stager.rs` | `MetaProcessError` |
| Meta processing | `semantics/meta/meta_processor.rs` | `MetaProcessError` |
| Evaluation | `runtime/interpreter.rs` | `EvalError` |

### Existing error variants

**`LoadError`**
```rust
Io { path: PathBuf, error: io::Error }
Parse { path: PathBuf, error: String }   // error is Debug-formatted ParseError
```

**`TypeError`**
```rust
InvalidReturn
Unsupported
UnboundVar(String)
TypeMismatch { expected: Type, found: Type }
```

**`MetaProcessError`**
```rust
ExprNotFound(usize)
StmtNotFound(usize)
EmbedFailed { path: String, error: String }
UnknownType(String)
Unimplemented(String)
UnresolvedSymbol(String)
CircularDependency
```

**`EvalError`** (runtime — most should never surface to the user)
```rust
ExprNotFound(usize) | StmtNotFound(usize)   // internal bugs
UnknownStructType(String)
UndefinedVariable(String)
TypeError(Type)
TypeCheckFailed(TypeError)
NonFunctionCall
ArgumentMismatch
GenOutsideMetaContext
Unimplemented
```

### Current unwrap locations in `main.rs`

```rust
load_compilation_unit(root_path).expect("failed to load compilation unit");  // line 29
type_check(meta_ast).unwrap();                                                // line 37
stage_all_files(...).unwrap();                                                // line 44
staged_forest.resolve_symbol_deps().unwrap();                                 // line 45
process(staged_forest, &mut evaluator).unwrap();                              // line 58
eval(...).unwrap();                                                           // line 75
```

---

## Visual Design

The target output follows the **Human-Centered Compiler Design** philosophy used by modern systems languages (rustc, elm, roc). The key pattern: every diagnostic is self-contained — the user can read only that block and understand what went wrong and how to fix it.

### Terminal rendering

```
× type mismatch
  ┌─ scratch/errors/main.cx:3:5
  │
3 │ var y = 1 + true;
  │             ~~~~ expected int, found bool
  │
  └─ help: the `+` operator requires both operands to be the same type

× missing return
  ┌─ scratch/errors/main.cx:8:1
  │
8 │ fn test() -> int {
  │ ^^^^^^^^^^^^^^^^ this function must return int on all paths
  │
  └─ help: consider adding return statements to all control flow branches
```

### Color scheme (terminal)

| Element | Color |
|---|---|
| Error prefix `×` | Red / bold |
| Error title | Bold white |
| File path + line:col | Cyan |
| Source code | Default |
| Annotation line `~~~~` | Magenta |
| `help:` label | Cyan |
| Help text | Default |
| Box drawing `┌ │ └` | Dim / grey |

### Anatomy of a diagnostic

```
× {error title}                          ← red ×, bold title
  ┌─ {file}:{line}:{col}                 ← cyan path
  │
N │ {source line}                        ← verbatim source
  │      ~~~~                            ← magenta: points to offending span
  │
  └─ help: {actionable suggestion}       ← cyan "help:", plain suggestion
```

### Multiple errors

The compiler reports **all errors found in a single pass** before exiting. Each error is separated by a blank line. After all errors, a summary line:

```
× 2 errors found. Compilation failed.
```

---

## Goal

### Phase 1 minimum (no source spans)

```
× unbound variable 'name'
  ┌─ scratch/errors/main.cx
```

### Phase 3 target (full spans + help)

```
× unbound variable 'name'
  ┌─ scratch/errors/main.cx:5:9
  │
5 │ var x = name + 1;
  │         ~~~~ not found in this scope
  │
  └─ help: check for a typo, or declare 'name' before this line

× type mismatch
  ┌─ scratch/errors/main.cx:9:14
  │
9 │ var y: int = "hello";
  │              ~~~~~~~ expected int, found string
  │
  └─ help: remove the type annotation or change the value to an int

× 2 errors found. Compilation failed.
```

### Behaviour

- Print to **stderr**, not stdout
- **Exit code 1** on any error, **exit code 0** on success
- **No panics** from compiler code (only genuine internal bugs, never user errors)
- Report **all errors** in a single pass where possible; stop at stage boundaries (e.g. don't run the type checker if parsing failed)
- Internal compiler bugs (e.g. `ExprNotFound`) display as `internal compiler error` with a bug report link

---

## Architecture

### 1. Unified `CompilerError`

New file: `src/error.rs`

```rust
pub enum CompilerError {
    Load(LoadError),
    TypeCheck(TypeError),
    Meta(MetaProcessError),
    Eval(EvalError),
}
```

Implement `std::error::Error` and `Display` for `CompilerError`. Each variant delegates to its inner error's display.

### 2. Diagnostic renderer

Each error is rendered through a single `Diagnostic` struct rather than raw `Display`. This keeps formatting logic in one place:

```rust
pub struct Diagnostic {
    pub title: String,              // shown after ×
    pub file: Option<PathBuf>,
    pub span: Option<Span>,         // line, col, len
    pub label: Option<String>,      // annotation under the span
    pub help: Option<String>,       // shown after └─ help:
}
```

`Diagnostic::emit(&self)` writes the formatted block to stderr using the box-drawing + color scheme above. Each error type implements `fn to_diagnostic(&self) -> Diagnostic`.

Phase 1: `span` and `label` are `None` — only title + file path render.
Phase 3: all fields populated.

**Example outputs (Phase 1):**

```
× file not found: scratch/errors/main.cx
× parse error in scratch/errors/main.cx: unexpected token ')'
× unbound variable 'name'
  ┌─ scratch/errors/main.cx
× type mismatch — expected int, found string
  ┌─ scratch/errors/main.cx
× unresolved symbol 'Foo'
× circular dependency detected between modules
× undefined variable 'x'
```

Internal bugs:
```
× internal compiler error: expression node not found (id=42)
  ┌─ please report this at https://github.com/brendancron/compiler/issues
```

### 3. `main.rs` refactor

Replace `run_pipeline` with a `Result`-returning function, handle at the top:

```rust
fn main() {
    let args = CliArgs::parse();
    let sink = DebugSink::from_args(&args);
    if let Err(e) = run_pipeline(&args.source_path, &sink) {
        eprintln!("{e}");
        std::process::exit(1);
    }
}

fn run_pipeline(root_path: &PathBuf, sink: &DebugSink) -> Result<(), CompilerError> {
    let files = load_compilation_unit(root_path)?;  // LoadError → CompilerError
    let (type_table, type_env) = type_check(meta_ast)?;  // TypeError → CompilerError
    // ... all stages use ? instead of unwrap
    Ok(())
}
```

`From` impls on `CompilerError` make `?` work:
```rust
impl From<LoadError> for CompilerError { ... }
impl From<TypeError> for CompilerError { ... }
impl From<MetaProcessError> for CompilerError { ... }
impl From<EvalError> for CompilerError { ... }
```

---

## Error Catalog

Full list of user-facing errors with title, annotation, and help text.

### Load / Parse Errors

| Code | Trigger | Title | Annotation | Help |
|---|---|---|---|---|
| E0001 | File not found | `no such file or directory` | — | `check the path and try again` |
| E0002 | File unreadable | `could not read '{path}'` | — | OS error message |
| E0003 | Lex error | `unexpected character '{c}'` | points to character | `remove or replace this character` |
| E0004 | Parse error | `unexpected token '{tok}'` | points to token | context-specific (e.g. `expected ')'`) |

### Type Errors

| Code | Trigger | Title | Annotation | Help |
|---|---|---|---|---|
| E0010 | `UnboundVar` | `unbound variable '{name}'` | `not found in this scope` | `check for a typo, or declare '{name}' before this line` |
| E0011 | `TypeMismatch` | `type mismatch` | `expected {expected}, found {found}` | depends on context (assignment, argument, return) |
| E0012 | `InvalidReturn` | `return outside of function` | `not inside a function body` | `move this return statement inside a function` |
| E0013 | Missing return | `function may not return a value` | points to fn signature | `add return statements to all control flow branches` |

### Meta / Staging Errors

| Code | Trigger | Title | Annotation | Help |
|---|---|---|---|---|
| E0020 | `UnresolvedSymbol` | `unresolved symbol '{name}'` | — | `check that '{name}' is exported from its module` |
| E0021 | `CircularDependency` | `circular module dependency` | — | list the cycle |
| E0022 | `EmbedFailed` | `could not embed '{path}'` | — | OS error |
| E0023 | `UnknownType` | `unknown type '{name}'` | points to annotation | `check spelling or add the type declaration` |

### Runtime / Eval Errors

| Code | Trigger | Title | Annotation | Help |
|---|---|---|---|---|
| E0030 | `UndefinedVariable` | `undefined variable '{name}'` | — | `this should have been caught by the type checker — please report` |
| E0031 | `NonFunctionCall` | `called a non-function value` | — | — |
| E0032 | `ArgumentMismatch` | `wrong number of arguments` | — | expected vs found count |
| E0033 | `TypeCheckFailed` | delegate to `TypeError` | — | — |

### Internal Errors

| Code | Trigger | Title |
|---|---|---|
| ICE | `ExprNotFound` | `internal compiler error: expression node not found (id={n})` |
| ICE | `StmtNotFound` | `internal compiler error: statement node not found (id={n})` |

All ICEs include: `please report this at https://github.com/brendancron/compiler/issues`

---

## Source Location Threading

Currently the compiler has **no source span information** in the AST or error types. This is the biggest gap between "ok" error messages and "great" error messages.

### Phase 1 (no spans — quick win)

Include the file path in each error. Sufficient for:
```
error: unbound variable 'name'
  --> scratch/errors/main.cx
```

This is achievable immediately since `LoadError` already carries `path`, and the pipeline knows which file it's processing.

### Phase 2 (token positions)

The lexer already tracks token positions (used in `ParseError`). Parse errors could show line + column if we convert token index → `(line, col)` by scanning the source.

Changes needed:
- `tokenize()` returns tokens with `(start_byte, end_byte)` or `(line, col)` alongside each token
- `ParseError` carries the position of the problematic token
- `LoadError::Parse` surfaces this through to `CompilerError`

### Phase 3 (AST spans)

Full `Span { file, line, col, len }` on every AST node. Allows pointing to the exact expression in type errors and runtime errors.

Changes needed:
- `MetaAst` nodes carry `Span`
- `TypeError` carries `Span` of the offending expression
- Error display renders the source line with a caret

### Source rendering

For Phase 3, use the **`ariadne`** crate. It produces exactly the box-drawing + colored annotation style described in the Visual Design section — `┌─`, `│`, `└─ help:`, column-level `~~~~` underlines, multi-label support — with no custom rendering code needed.

`ariadne` integrates via a `Cache` trait (provide source text by file ID) and a `Report` builder:

```rust
Report::build(ReportKind::Error, file_id, span.start)
    .with_message("type mismatch")
    .with_label(Label::new((file_id, span)).with_message("expected int, found string"))
    .with_help("remove the type annotation or change the value to an int")
    .finish()
    .eprint(sources)?;
```

**Alternative:** `codespan-reporting` — similar capability, slightly less expressive label style. `ariadne` is preferred for the exact visual target.

---

## Implementation Plan

### Phase 1 — No panics, readable messages (do first)

**Effort: ~2 hours**

- [ ] Add `to_diagnostic()` to `TypeError`, `MetaProcessError`, `EvalError` (no spans yet — title only)
- [ ] Create `src/error.rs`: `CompilerError` enum, `Diagnostic` struct, `Diagnostic::emit()`
- [ ] `Diagnostic::emit()` renders `× title` + `┌─ path` to stderr using `termcolor` or raw ANSI codes
- [ ] `CompilerError` gets `From` impls for all inner error types
- [ ] Refactor `main.rs`: `run_pipeline` returns `Result<(), CompilerError>`, all `.unwrap()` → `?`
- [ ] `main()` catches, calls `e.emit()`, exits 1

**Result:** No more panic backtraces. Users see `× unbound variable 'name'  ┌─ main.cx`.

### Phase 2 — Parse error line numbers

**Effort: ~half day**

- [ ] Extend `Token` to carry byte offset (`start: usize`, `end: usize`)
- [ ] `ParseError` carries the offending token's `start` offset
- [ ] `LoadError::Parse` carries `(path, source, offset)` — source text needed to convert offset → line/col
- [ ] `Diagnostic::emit()` converts offset to `(line, col)` by counting newlines in the source prefix
- [ ] Error display: `× unexpected token ')'\n  ┌─ main.cx:12:8`

### Phase 3 — Full source spans + ariadne

**Effort: ~1-2 days**

- [ ] Add `ariadne` to `Cargo.toml`
- [ ] Add `Span { start: usize, end: usize }` to AST expression and statement nodes
- [ ] `TypeError` and `MetaProcessError` carry `Span` of the offending node
- [ ] Replace `Diagnostic::emit()` with `ariadne::Report` construction
- [ ] Each `to_diagnostic()` populates labels and help text from the catalog above
- [ ] Source text is cached per file via `ariadne::Source`

**Result:** Full box-drawing output with column-level `~~~~` annotations and `└─ help:` suggestions.

### Phase 4 — Multi-error collection

**Effort: ~half day**

- [ ] Type checker accumulates errors into `Vec<TypeError>` rather than returning on first
- [ ] `run_pipeline` returns `Vec<CompilerError>` and continues past type errors to collect more
- [ ] All diagnostics emitted, then summary line: `× N errors found. Compilation failed.`
- [ ] Stop at stage boundary: don't run meta-processing if parsing failed; don't run eval if type check failed

---

## Files to Create / Modify

| File | Change | Phase |
|---|---|---|
| `src/error.rs` | NEW — `CompilerError`, `Diagnostic`, `Diagnostic::emit()`, `From` impls | 1 |
| `src/main.rs` | `run_pipeline` returns `Result`, all `.unwrap()` → `?`, error handler at `main()` | 1 |
| `src/semantics/types/type_error.rs` | Add `to_diagnostic()` | 1 |
| `src/semantics/meta/meta_process_error.rs` | Add `to_diagnostic()` | 1 |
| `src/runtime/interpreter.rs` | Add `to_diagnostic()` to `EvalError` | 1 |
| `src/frontend/token.rs` | Add `start: usize, end: usize` to `Token` | 2 |
| `src/frontend/lexer.rs` | Populate byte offsets on tokens | 2 |
| `src/frontend/parser.rs` | `ParseError` carries token offset | 2 |
| `src/frontend/module_loader.rs` | `LoadError::Parse` carries source text + offset | 2 |
| `Cargo.toml` | Add `ariadne` dependency | 3 |
| `src/frontend/meta_ast.rs` | Add `Span` to expression and statement nodes | 3 |
| `src/semantics/types/type_error.rs` | Add `Span` field, full `ariadne` label | 3 |
| `src/error.rs` | Replace `Diagnostic::emit()` with `ariadne::Report` | 3 |
