# Modules

Status: **built.** `lib/loader.ml` reads the transitive closure of imports and hands the rest of the pipeline one program; `tests/core/modules/` passes. Thirteen fixtures under `tests/stdlib/` are still tagged for modules, and every one is blocked on its *source* — `struct`, `[int]` and `;` separators from before the type redesign — rather than on the loader.

## What a program can write

Five forms, all of them already fixtured.

```cronyx
import "util";                          // the namespace is the basename
import "helpers" as h;                  // renamed
import { greet } from "helpers";        // selective, and unqualified at the use
import "utils/*";                       // every file in a directory, each its own namespace
import "../../../stdlib/lang/Option";   // relative to the importing file
```

A path has no extension, uses `/`, and resolves **relative to the file containing the `import`** — not to the entry point and not to a root. `..` is ordinary. `utils/*` reads every `.cx` in that directory and binds each under its own basename.

Access is qualified by default: `util.foo()`, `h.greet("World")`, `math.add(3, 4)`. A selective import binds the name directly instead.

Every top-level declaration is exported. Restricting that is [deferred](#five-decisions).

## Circular imports work

`tests/core/modules/circular` is two files that import each other, and `peer.run()` calls `main.hello()`. This is not a diagnostic to produce — it is behavior to support.

That single requirement decides the compilation model.

## Five decisions

The test each of these is held to: **does the concept do more than one job?** A module system that fails it becomes a second language beside the first, which is the common way this feature goes wrong.

**1 · A module is a file.** No `module X { }` blocks, no submodule syntax, no packages yet. One rule, unfightable, and the one the fixtures already assume.

**2 · An import binds a compile-time value.** A module is a record that exists during compilation. Everything else follows from that rather than being its own feature:

| Written | Is |
|---|---|
| `math.add(3, 4)` | field access, constant-folded into a direct call |
| `import "helpers" as h` | binding the same value to another name |
| `import { greet } from "helpers"` | destructuring it |
| a `meta fn` taking a module and emitting declarations | a functor |

**3 · Visibility is deferred.** Every declaration is currently exported. `pub` with a private default was the plan and is held back pending a separate design; the loader does not depend on which way it goes, since visibility is a filter over a unit's exports and the export list already exists. What it costs to postpone is one pass over the prelude and the fixtures later, and it leaves `l.count = 99` breaking `l.len()` until then.

**4 · An imported unit contributes declarations only.** Its top-level statements are rejected, not dropped.

**5 · `gen` splices with definition-site scoping.** A name in generated code means what it meant where the generator was written, not where it was used.

## The model: one program, resolved names

The loader reads the transitive closure of imports and hands the existing pipeline **one** program. Each unit's top-level declarations are renamed `unit__name`, the convention `Type__method` already uses, and qualified references are rewritten to the resolved name.

The loader is given the roots it may reach: the package being compiled, the standard library, and each dependency under the name the manifest gave it. A path import resolves relative to the file that wrote it and may not leave that file's own root, so a dependency's module can move within the dependency and not within whoever imported it. A unit's namespace comes from the import as written rather than from the file it resolved to, because a dependency's root module is `src/lib.cx` and is reached as the package's name. See [Package Manager.md](Package%20Manager.md).

```cronyx
// math.cx
pub fn add(a, b) { return a + b; }

// main.cx
import "math";
print(math.add(3, 4));
```

becomes one program holding `fn math__add(a, b)` and a call to `math__add`.

Mangling and decision 2 are not rival designs — they are the same thing at two phases. **The resolve pass is the compile-time evaluation of a module value in the trivial case**, where the field being read is known and the answer is a name. A `meta fn` is the same evaluation when the answer is not a name but a set of declarations. Nothing new is introduced to get the second from the first.

Three things follow, and they are the reason for the choice.

**A cycle stops being one.** A cycle only exists if units are compiled separately. Concatenated, `peer.run()` and `main.hello()` are ordinary forward references, and the checker's hoist pass already handles those.

**A module is never a *runtime* value.** It exists at compile time and is gone by the interpreter, so the checker is never asked whether a receiver is a namespace or a value — the question is answered before it runs, in the one part of the checker that was least sound.

**Module-level compiler state stays correct.** `ctx_types`, `ctx_methods`, `Resolve.declared_rows` and the rest are global, which is wrong for *separate* compilation and exactly right for one program. It is not a prerequisite here.

## The pass

One new pass, between parsing and `Desugar`:

```
load → parse each unit → resolve imports and mangle → concatenate → Desugar → …
```

It owns path resolution, the import graph, the per-unit alias table, and the rewrite. Nothing downstream learns that modules exist.

**Wildcards expand in the loader**, before anything else runs: `import "utils/*"` becomes one plain import per `.cx` in that directory, sorted so the expansion is deterministic. Only three forms reach the rest of the compiler, and `Wildcard` is unrepresentable in a loaded program rather than merely unexpected.

## Ordering

**Declarations hoist**, so their order across units does not matter — that is what makes a cycle work.

**Only the entry's top-level statements run.** An imported unit contributes its declarations and nothing else. This is the rule the Rust bootstrap arrived at, and it is better than running each unit's statements in dependency order: it removes the question of what a cycle's initialization order is, because there is no initialization to order.

Where it differs is that a non-declaration in an imported unit is **rejected**, not dropped. Rust filters silently, so a `var` at a module's top level vanishes with no diagnostic; a module is a set of declarations and saying so is cheaper than explaining where the statement went.

**Phase separation falls out of this**, and that is the larger payoff. Racket needs `require for-syntax` because its modules do work at both phases. If importing a unit cannot run anything, there is nothing to separate: "a meta block sees imported declarations, never imported runtime values" stops being a rule to enforce and becomes a consequence of the design. The rule is discharged rather than implemented.

**A local shadows a namespace.** If a unit binds `math` as a variable, `math.add` is a field or method access on that value, not the module. The alias table is consulted only when nothing else in scope has the name.

## `embed` reads a file where the program is put together

`embed("data.bin")` becomes the file's contents. The loader does it, because the loader is what knows where the source that wrote it lives — the path resolves against that file's directory, the way an `import` does, not against wherever the compiler was run from.

**It yields bytes, not a string.** `Array<byte>`, undecoded: what is embedded need not be text, and a program that wants text says so. Held as one node rather than an octet apiece, so embedding a megabyte costs one literal instead of a million.

A file that is not there is a load error naming it, at the span of the call.

## `readfile` and `writefile` resolve the same way

Both take a path relative to the file that wrote the call, resolved through the
span the builtin is handed — the same rule as `import` and `embed`, so where the
compiler was started from is never something the source can see.

`readfile` yields a `string` rather than the bytes `embed` gives, because it is
reached while the program runs and a program that wanted bytes would decode
them itself. A path that cannot be read is a runtime error naming the path *as
written*, not as resolved: what the reader has in front of them is the former.

**They work at compile time too.** A `meta` block calling `readfile` reads while
compiling, and what it read can be baked into generated code — `embed` with a
shape decided by the program rather than by the compiler.

## Spans carry a file

`Ast.span` was `{ line; col }`, and concatenating four units would have made `[3:5]` name nothing. It now carries the file, threaded through the *token* so that no `span_of_token` call site changed. `Ast.locate ~entry` prints a bare `[3:5]` while a span is in the unit being compiled and `[lib.cx 2:12]` once it is not, rendered relative to the entry's directory.

The prelude is still a string in `lib/prelude.ml` rather than a unit the loader reads, but it scans under the name `<prelude>`, so a diagnostic from inside it says so instead of pointing at a line in the user's file.

## What this does not do

**Separate compilation** is a design rather than a task: `Type_mono` runs on typed IR, so a compiled unit would have to carry the typed body of every exported generic. Rust ships generic MIR in rlib metadata, C++ puts templates in headers, OCaml declines to monomorphize. None of it is needed to run 23 fixtures, and choosing it later does not invalidate the mangling.

**Signatures and sealing as a separate feature.** `trait` already describes an interface. If a module wants one it is an interface over declarations, later, not a module type system now.

**Re-exports, `module { }` blocks, runtime module values.** Each is one more concept doing one job.

**Packages.** They arrive as the boundary where cycles are *rejected* and interfaces are shipped — remediation 6's territory. Cycles staying legal within a program is coherent precisely because a program is one unit, the way they are legal inside a Rust crate and illegal between them.

**A functor feature.** Not because functors are unwanted, but because a `meta fn` over a compile-time module value already is one. Building a second abstraction mechanism beside static params is how a language ends up with two ways to do everything.

## What the Rust bootstrap did

`legacy-bootstrap/src/frontend/module_loader.rs` is 196 lines and the design above agrees with most of it: a breadth-first walk with a `visited` set so cycles load rather than fail, paths canonicalized and resolved against the importing file's directory with `.cx` appended, wildcards expanded before the rest of the pipeline, and every unit's declarations merged into one tree with the entry's statements last. Two things were taken from it directly — the wildcard expansion and the entry-only statement rule.

Three things are deliberately different.

**Namespaces resolve by mangling, not by an export list.** Rust keeps a `ModuleBinding::Namespace { bind_name, exports }` where each export is a `(name, node_id)` pair, with the comment that node IDs are what keep two modules' `add` apart. `bootstrap` has no node IDs, and `unit__name` is unique by construction. The cost is a collision this design has to state: a module `a_b` with `fn c` and a module `a` with `fn b__c` mangle alike. A reserved separator or a rejection at load is the fix, and it is the same problem `Ast.method_name` already has.

**Namespace access is type checked.** Rust binds an imported namespace to a *fresh type variable* (`runtime_type_checker.rs:681`), so `util.foo()` is unchecked — the same shape as the receiver heuristic this bootstrap removed. Mangling turns `util.foo(x)` into an ordinary call before the checker runs, so it is checked like any other.

**Diagnostics carry a file.** Rust builds a span table per file and then surfaces only the entry's to `main`, so an error inside an imported unit has no location. That is the failure this design's span prerequisite exists to avoid, and it is worth seeing before repeating.

One caution rather than a difference: Rust auto-loads six `stdlib/lang` files into every program, with a comment that only files "with no heavy transitive deps" are safe because the others "define conflicting globals". An always-on prelude and a flat global namespace produce exactly that. Renaming per unit removes most of it — two modules may both declare `add` — but it does not remove it for the prelude, which is unqualified by design, and that is the pressure visibility will eventually have to answer.

## Open

**A selective import colliding with a local declaration.** `import { greet } from "helpers"` followed by `fn greet()` in the same unit. Rejecting it is the safe answer; nothing yet says so, and nothing detects it.

**A namespace can be reached but a type cannot be re-exported.** A unit's declarations are renamed and its imports are stripped, so `import "a"` in unit `b` does not make `a`'s names reachable as `b.something`. That is the intended shape, but nothing says so and nothing rejects the attempt.

**Two diagnostics have no fixture.** A duplicate namespace binding and a duplicate selective name are both rejected at load — `'util' is already bound. Import one of them with 'as'.` — and neither is pinned by a test.

**Display of generated names.** `typeof` prints `geom#Point`. The mapping back to `geom.Point` belongs with the `typeof` rework rather than here.
