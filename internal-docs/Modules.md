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

Access is qualified by default: `util.foo()`, `h.greet("World")`, `math.add(3, 4)`. A selective import binds the name directly instead. Anything a module declares is reached the same way, not only a call: `util.f<1>()` instantiates a template out of `util`, and `animals.Cat` names a type, whether as a unit value or in `derive named.Named for animals.Cat;`.

Every import says which module a name comes from — `utils/*` too, since each file keeps its basename. An import that brings a module's names in unqualified, Rust's `use m::*`, is ruled out for now: see [A module's meta runs at its first reference](#a-modules-meta-runs-at-its-first-reference) for why, and [TODO.md](TODO.md) for what is open about it.

Every top-level declaration is exported. Restricting that is [deferred](#five-decisions).

## Circular imports work

`tests/core/modules/circular` is two files that import each other, and `peer.run()` calls `main.hello()`. This is not a diagnostic to produce — it is behavior to support.

That single requirement decides the compilation model.

## Five decisions

The test each of these is held to: **does the concept do more than one job?** A module system that fails it becomes a second language beside the first, which is the common way this feature goes wrong.

**1 · A module is a file, or a directory of modules.** No `module X { }` blocks and no submodule syntax: the file system is the structure. A file is a module of declarations; a directory is a module holding the modules inside it, so `import "api/"` over `api/users.cx` and `api/assets.cx` binds `api`, and `api.users.list()` reaches into it. The trailing slash is what says a directory, as it does in a path: `import "api"` is the file `api.cx`, so a file and a directory of one name never collide, and importing both needs `as`, since both bind `api`. Leaving the slash off a directory, or putting one on a file, is an error naming the form that was meant. A directory is how a group of modules is named and reflected as one — `moduleof(api)` describes all of it. The wildcard stays beside it for the other need: `import "api/*"` binds `users`, `containers` and `assets` as separate names rather than the group under one. Directory imports are not built yet; `import "api/users"` binding `users` is, and so is the wildcard.

**2 · A module is not a value; it is reflected, like a type.** An import binds a name for resolution and nothing else. `var m = math;` is an error, as `var t = Dog;` is: a type is looked at through `typeof(Dog)`, which gives a `Type` record, and a module is looked at the same way, through `moduleof(math)`, which gives a `Module` record: a sum, since a module is a file or a directory.

```cronyx
type Module {
    File(Name, Array<Declaration>),       // its top-level declarations, written or generated
    Directory(Name, Array<Module>),       // the modules inside it
}
// Declaration is { name: Name, kind: DeclarationKind, attrs: Array<Attr> }
```

A file's declarations are its top-level ones, mirroring `TypeField`, with `kind` one of `Function`, `Type`, `Trait`, `Effect` and `Handler`: every named declaration, written or generated. An impl has no name and is reached through its type, so it is left out until something needs it; a method is reached through its type and a local function not at all. Collecting everything under a directory is a small recursive library function rather than a second form of the call. `packageof(name)` describes a package the same way, its root being a `Directory`.

`typeof`, `moduleof` and `packageof` take static constructs — a name the source binds, a static parameter — never a run-time value. The walk answers them while it runs, and `moduleof(api)` is itself the reference that runs `api`'s top-level `meta`, so what it is asked about has to be known then. The record is ordinary data, so it can be looped over, filtered and passed to a function; the module itself cannot.

| Written | Is |
|---|---|
| `math.add(3, 4)` | a name resolved to `math`'s `add` |
| `import "helpers" as h` | the same resolution under another name |
| `import { greet } from "helpers"` | `greet` resolved to `helpers`'s |
| `moduleof(helpers)` | a `Module` record describing it, and a reference to it — so its top-level `meta` runs first, and the record includes what that generates |

Zig makes a file a struct value. Cronyx does not, so the checker never meets a module in type position, and there is one reflection idea for everything: the thing itself cannot be held, only a description of it. What that gives up is handing a module to a function; a function with static parameters can be handed a module's *description* and generate declarations from what it declares, which is what a functor is used for. `moduleof` is not built yet ([TODO](TODO.md), "When a declaration query runs").

**3 · Visibility is deferred.** Every declaration is currently exported. `pub` with a private default was the plan and is held back pending a separate design; the loader does not depend on which way it goes, since visibility is a filter over a unit's exports and the export list already exists. What it costs to postpone is one pass over the prelude and the fixtures later, and it leaves `l.count = 99` breaking `l.len()` until then.

**4 · An imported unit contributes declarations only.** Its top-level statements run when it is the entry file and are loaded as nothing when it is imported.

**5 · `gen` splices with definition-site scoping.** A name in generated code means what it meant where the generator was written, not where it was used.

## The model: one program, resolved names

The loader reads the transitive closure of imports and hands the existing pipeline **one** program. Each unit's top-level declarations are renamed `unit__name`, the convention `Type__method` already uses, and qualified references are rewritten to the resolved name.

The loader is given the roots it may reach: the package being compiled, the standard library, and each dependency under the name the manifest gave it. A path import resolves relative to the file that wrote it and may not leave that file's own root, so a dependency's module can move within the dependency and not within whoever imported it. A unit's namespace comes from the import as written rather than from the file it resolved to, because a dependency's root module is `src/lib.cx` and is reached as the package's name. See [Package Manager.md](Package%20Manager.md). A package's artifact is its units at this point — loaded and mangled, not metaprocessed — so a dependency's meta blocks and templates run when the linked program is walked, like everyone else's.

```cronyx
// math.cx
pub fn add(a, b) { return a + b; }

// main.cx
import "math";
print(math.add(3, 4));
```

becomes one program holding `fn math__add(a, b)` and a call to `math__add`.

Mangling is what decision 2 comes to: a module is only ever a question about names, answered by rewriting them, and reflecting one is the same question asked from a `meta` block.

Three things follow, and they are the reason for the choice.

**A cycle stops being one.** A cycle only exists if units are compiled separately. Concatenated, `peer.run()` and `main.hello()` are ordinary forward references, and the checker's hoist pass already handles those.

**A module is never a value.** It is resolved away before the checker runs, so the checker is never asked whether a receiver is a namespace or a value — the question is answered before it runs, in the one part of the checker that was least sound.

**Module-level compiler state stays correct.** `ctx_types`, `ctx_methods`, `Resolve.declared_rows` and the rest are global, which is wrong for *separate* compilation and exactly right for one program. It is not a prerequisite here.

## The pass

One new pass, between parsing and `Desugar`:

```
load → parse each unit → resolve imports and mangle → concatenate → Metaprocess → Desugar → …
```

It owns path resolution, the import graph, the per-unit alias table, and the rewrite. Nothing downstream learns that modules exist.

**Wildcards expand in the loader**, before anything else runs: `import "utils/*"` becomes one plain import per `.cx` in that directory, sorted so the expansion is deterministic. Only three forms reach the rest of the compiler, and `Wildcard` is unrepresentable in a loaded program rather than merely unexpected.

## Ordering

**Declarations hoist**, so their order across units does not matter — that is what makes a cycle work.

**Only the entry's top-level statements run.** An imported unit contributes its declarations and nothing else. This is the rule the Rust bootstrap arrived at, and it is better than running each unit's statements in dependency order: it removes the question of what a cycle's initialization order is, because there is no initialization to order.

A module's statements are not an error, though. A file can be a library and a program at once — its statements run when it is the file being run, and importing it loads only its declarations (`tests/core/modules/module_statements`) — so the statements are what makes it runnable rather than a mistake to report.

**Phase separation falls out of this**, and that is the larger payoff. Racket needs `require for-syntax` because its modules do work at both phases. If importing a unit runs none of its statements, there is nothing to separate: "a meta block sees imported declarations, never imported runtime values" stops being a rule to enforce and becomes a consequence of the design. The rule is discharged rather than implemented.

## A module's meta runs at its first reference

**An import is symbol resolution and nothing else.** A module's top-level `meta` blocks and `derive`s count as declarations, and the loader marks them to wait: they run the first time the metaprocessing walk asks that module for a name, once, however many units import it. Moving an import line changes nothing, and a module nothing reachable references never runs its meta at all. `tests/meta/06_modules/` pins it — `first_reference` prints `main before`, `main after` and only then `util meta`, when `util.foo()` is reached.

What a module's meta block generates is part of the module: a generated declaration takes the module's prefix, and a generated statement is dropped, as a written one would be. A template in a module is instantiated like one anywhere else, memoized across the whole program, so two importers asking for `util.f<1>()` share one copy (`template_two_importers`).

This works only because every name says which module it comes from. An unqualified wildcard import would let a bare name come from any of several modules, and since a meta block can generate anything, every one of them would have to run before the name resolved — which is why imports stay qualified.

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

**Re-exports, `module { }` blocks, module values.** Each is one more concept doing one job.

**Packages.** They arrive as the boundary where cycles are *rejected* and interfaces are shipped — remediation 6's territory. Cycles staying legal within a program is coherent precisely because a program is one unit, the way they are legal inside a Rust crate and illegal between them.

**A functor feature.** Not because functors are unwanted, but because a function with static parameters whose `meta` block reads a module's description and emits declarations already covers what one is used for. Building a second abstraction mechanism beside static params is how a language ends up with two ways to do everything.

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
