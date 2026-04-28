# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All commands run from repo root unless noted.

```bash
# Build
make rust                          # release build
cd bootstrap && cargo build        # dev build

# Test
make test                          # all tests
cd bootstrap && cargo test         # all Rust tests
cd bootstrap && cargo test <name>  # single test by name (substring match)
cd bootstrap && cargo test --test script_integration    # one test file
cd bootstrap && cargo test --test compile_integration   # compile tests
cd bootstrap && cargo test -- --nocapture               # show stdout

# Run
cargo run --manifest-path bootstrap/Cargo.toml -- path/to/file.cx
cargo run --manifest-path bootstrap/Cargo.toml -- path/to/file.cx --compile --out /tmp/bin

# Suppress warnings during test iteration
cd bootstrap && RUSTFLAGS="-A warnings" cargo test
```

**Useful CLI flags** (passed to the compiler binary):
- `--compile --out <path>` — emit native binary via LLVM instead of interpreting
- `--dump-all --out-dir out` — write debug files for every pipeline stage
- `--dump-runtime-ast`, `--dump-cps`, `--dump-staged`, etc. — individual stage dumps

## Architecture

Cronyx is a statically-typed, metaprogramming-first language. The compiler lives entirely in `bootstrap/src/`.

### Pipeline (in order)

```
Source files
  → frontend::module_loader       load compilation unit (entry + imports)
  → frontend::{lexer, parser}     tokenize + parse → MetaAst
  → semantics::types::type_checker        Phase 1 HM type inference (permissive)
  → semantics::meta::meta_stager          identify staged (compile-time) functions
  → semantics::meta::meta_processor       execute staged code → RuntimeAst
      uses: semantics::meta::interpreter_meta_evaluator
            semantics::meta::monomorphize
  → semantics::cps::effect_marker         mark which functions need CPS
  → semantics::cps::cps_transform         rewrite those functions to pass continuations
  → semantics::types::runtime_type_checker  Phase 2 strict type check → type_map
  → [branch]
      codegen::compile            LLVM IR → native binary (--compile flag)
      runtime::interpreter        tree-walking interpreter (default)
```

### Key distinctions

**Two ASTs**: `MetaAst` is the parsed form (includes compile-time constructs). `RuntimeAst` is post-metaprocessing (all staging resolved, generics monomorphized). The CPS transform and type_map operate on `RuntimeAst`.

**Two type-checking phases**: Phase 1 (`type_checker`) is permissive — unbound vars get fresh type vars because metaprogramming may introduce bindings. Phase 2 (`runtime_type_checker`) is strict and runs after all staging is resolved.

**Metaprogramming via staging**: `staged_forest` builds a dependency graph of compile-time functions. The meta evaluator executes them to produce generated code that becomes part of `RuntimeAst`.

**CPS is selective**: `effect_marker` identifies only functions that perform control effects; `cps_transform` rewrites only those. This is groundwork for the algebraic effects system.

### Module map

| Path | Role |
|------|------|
| `src/main.rs` | CLI entry, orchestrates full pipeline |
| `src/args.rs` | Argument parsing (no external lib) |
| `src/frontend/` | Lexer, parser, module loader, MetaAst definition |
| `src/semantics/types/` | Type definitions, HM inference, runtime type checker |
| `src/semantics/meta/` | Staging, meta-evaluation, monomorphization, RuntimeAst definition |
| `src/semantics/cps/` | Effect marking and CPS transform |
| `src/runtime/` | Tree-walking interpreter, value representation, environment |
| `src/codegen/` | LLVM codegen via inkwell (Milestone 0: arithmetic + print) |
| `src/util/` | `IdProvider` (unique AST node IDs), formatters |
| `src/error.rs` | `CompilerError` + `Diagnostic` (span-enriched errors) |

### Test fixtures

`tests/` (repo root, not `bootstrap/tests/`) contains `.cx` source + `.txt` expected-stdout pairs organized by category: `core/`, `effects/`, `meta/`, `operators/`, `types/`, `compile/`.

Compile tests additionally have `.ll` expected IR files for regression (target triple line stripped before comparison).

### LLVM setup

`bootstrap/.cargo/config.toml` sets `LLVM_SYS_200_PREFIX=/usr/local/opt/llvm@20`. inkwell 0.9 with feature `llvm20-1`. Uses opaque pointers (`context.ptr_type(AddressSpace::default())`). Shells out to `clang -Wno-override-module` for linking.
