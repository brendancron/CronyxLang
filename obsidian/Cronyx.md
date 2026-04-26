# Cronyx

## Language Goals

Cronyx is a simple, expressive language designed to be as approachable as Python or JavaScript while providing modern language features — metaprogramming, static type inference, and a clean module system.

Metaprocessing is a first-class feature in Cronyx. It enables higher-order code generation at compile time, supporting use cases such as reflection and code synthesis, without sacrificing runtime performance.

## Architecture

The defining characteristic of Cronyx's compilation pipeline is when metaprogramming runs. Most languages with macro or code generation systems process them in a preprocessing stage — before lexing or parsing. This approach works, but creates a "two-language" effect where macros feel like a separate system from the language itself.

In Cronyx, metaprogramming is deferred until after full syntactic analysis. The compiler builds a complete AST for all source files first, then reduces it through the Metaprocessor — a compile-time evaluator that executes `meta {}` blocks and folds their generated output back into the AST. The result is a runtime AST containing no meta constructs, only ordinary language statements.

This means metaprogramming uses the same syntax, types, and semantics as regular Cronyx code.

**Pipeline stages:**

1. **Lexer** — tokenizes source text
2. **Parser** — builds the MetaAST from tokens
3. **Type Checker** — infers and annotates types (Hindley-Milner), phase 1
4. **Metaprocessor** — evaluates `meta {}` blocks and emits the runtime AST
5. **Effect Marker** — identifies functions that perform `ctl` effects
6. **CPS Transform** — selectively rewrites effectful functions to pass continuations
7. **Type Checker** — phase 2, strict check on the final runtime AST
8. **Interpreter / Codegen** — evaluates the runtime AST or emits LLVM IR

## Type System

Cronyx is strongly typed, statically typed, and uses type inference. Types are inferred using the Hindley-Milner algorithm, so most code requires no explicit type annotations.

See [Type System](TypeSystem.md) for details.

## Algebraic Effects

Cronyx has first-class algebraic effects. Effects are declared with `effect`, handled with `run {} handle eff {}`, and support both transparent `fn` ops (function replacement) and suspending `ctl` ops (continuation passing). See [Cronyx Language Reference](Cronyx%20Language%20Reference.md) for syntax and [Effect Typing](Effect%20Typing.md) for the type system design.

## Memory Management

The current runtime uses reference counting. The final memory management strategy for compiled targets is under design.

## Module System

See [Cronyx Module System](Cronyx%20Module%20System.md).
