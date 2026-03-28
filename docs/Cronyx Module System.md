# Import System Design

## Core Philosophy

The file is the module. No declaration steps, no registration, no magic.
Imports tell the compiler where to look for symbols — they are search
directives, not hard dependency edges. The compilation unit (executable
or library) is treated as a single flat universe of symbols.

---

## Rules

### 1. File = Module
A file existing in the project means it is available. There is no
separate declaration step to opt a file into the build.

### 2. Same-Directory Scope Sharing
Files in the same directory automatically share scope. No import
statement is needed to reference a sibling file's symbols. Small
projects feel like one big file.

### 3. Imports Are Search Directives
`import` tells the compiler to look in a given file or directory when
resolving unknown names. It does not create a hard dependency edge.
Circular symbol references are allowed — the compiler collects all
declarations across all files first, then resolves references against
the full universe.

### 4. Qualified By Default
Imported names are always namespace-qualified. This keeps the origin
of every name visible and prevents collision confusion.
```
import "models"
import "legacy/models"

var x = models.User { ... }
var y = legacy_models.User { ... }
```

The namespace is derived from the **basename** of the import path.
When a path segment would collide (`models` vs `legacy/models`) the
slash is replaced with underscore: `legacy_models`.

### 5. Opt-In Selective Import
For brevity, specific names can be imported directly into scope.
This is an advanced escape hatch, not the default.
```
import { sqrt, pow } from "utils/math"
sqrt(2.0)
```

### 6. Aliases
Namespaces can be aliased to avoid verbosity or collision.
```
import "utils/math" as m
m.sqrt(2.0)
```

---

## Import Syntax

Import paths are **string literals**, not bare identifiers. This supports
nested paths and makes the string-vs-identifier distinction clear.

```
import "utils"           // namespace: utils
import "legacy/models"   // namespace: legacy_models
import { foo } from "utils"
import "utils" as u
```

> **Note:** The current parser uses `import util;` with a bare identifier.
> This needs to be updated to string-literal paths before the module system
> is implemented.

---

## Compiler Resolution Model

Resolution is a two-pass process:

1. **Collection pass** — all declarations across all files in the
   compilation unit are gathered into a single symbol universe.
2. **Resolution pass** — all references are resolved against that
   universe. Import statements narrow the search space for this pass.

This means:
- Files can reference symbols defined in files not yet processed
- Circular symbol references are fine (A references B, B references A)
- Circular *imports* (A imports B, B imports A) are allowed since
  imports are not dependency edges — they are hints
- Struct containing itself by value is a type system error, not an
  import error

### Integration with the StagedForest

The compiler's `StagedForest` orders meta trees using Kahn's topological
sort over `ProcessDependency` edges. The `SymbolTree` dependency type we
added tracks which tree provides a symbol that another tree consumes —
this is correct for **meta-time** ordering (a meta block that generates
`fn greet` must run before the tree that uses `greet` at meta-time).

For **runtime** symbols from imported files, SymbolTree deps must **not**
create ordering constraints that would deadlock mutual imports. The
resolution is:

- All imported files that are not meta-heavy are merged into the root
  tree's runtime AST as siblings. Their ordering is handled by function
  hoisting, not Kahn's algorithm.
- `SymbolTree` deps are only generated for symbols consumed at **meta
  execution time** (inside `meta { }` blocks), not for runtime call sites.

This means circular imports at the runtime level are always safe. Circular
imports where a meta block in A depends on a meta block in B which depends
on A's meta output would still be caught as a genuine cycle.

---

## Same-Directory Scope Sharing: Implementation Notes

Auto-scope requires the compiler entry point (not the staging layer) to
discover and parse sibling files. Concretely, before staging begins:

1. Glob all `.cx` files in the same directory as the entry file
2. Parse each one
3. Merge their `sem_root_stmts` into the same root `StagedAst`
   (or stage them as sibling trees with no ordering constraint between them)

A name declared in `helpers.cx` is accessible from `main.cx` without
any import statement — they share one flat scope.

**Edge case:** Two sibling files both declare `fn foo()` → name collision
error. Must be caught during the collection pass.

---

## Meta + Imports

The interaction between `meta { }` blocks and the module system is not yet
fully specified. Known constraints:

- `typeof(name)` in a meta block should work across file boundaries —
  the type of `name` must be known before the meta block runs.
- `gen fn foo() { ... }` in one file generating a symbol used in another
  file requires that the generating meta block is processed first. This is
  handled naturally by the existing `MetaTree` dependency, as long as both
  files are in the same forest.
- **Open question:** Can a meta block in file A use a function defined in
  file B's meta block? Answer: yes, provided the symbol dep ordering
  resolves correctly (MetaTree and SymbolTree deps together).

---

## Visibility

- Symbols are exported by default (exact mechanism TBD)
- Internal/private visibility is opt-in complexity, not required for
  basic use

---

## Beginner Experience

A beginner writing a small project never needs to know most of this:

- Put files in the same directory → they just work together
- Need something from another directory → `import "that/directory"`
- Name collision → add an alias

That is the entire mental model for 90% of use cases.

---

## What Was Deliberately Left Out

| Feature                                  | Reason Omitted                                            |
| ---------------------------------------- | --------------------------------------------------------- |
| Explicit module declaration (`mod`)      | Solves problems beginners don't have; add later if needed |
| Namespace-independent-of-file (C# style) | Confuses beginners; complicates compiler                  |
| Unqualified imports by default           | Causes name collision confusion                           |
| Forced circular import ban               | Unnecessary given two-pass resolution model               |

## Import Execution Semantics

When a file is imported (whether via explicit `import` or same-dir auto-scope):

- **Function and type declarations** (`fn`, `struct`) — collected and available in the importing scope
- **Meta blocks** (`meta { }`) — **run at compile time**, same as if the meta block were in the entry file
- **Variables** (`var`) — **not exported**; variables represent mutable state that should not leak across file boundaries. Shared constants are a future `const` concern.
- **Top-level imperative code** (expression statements, `print`, bare function calls) — **not executed**

Only the entry file's top-level imperative code runs at runtime. This preserves test
isolation, prevents surprise side effects from imports, and is consistent with the
principle that meta is a compile-time concern (so meta blocks always run) while runtime
execution belongs to the program entry point.

Example:
```
// helpers.cx
fn greet(name) { print("Hello, " + name); }   // collected ✓
struct Point { x: Int, y: Int }                // collected ✓
meta { gen fn debug() { ... } }                // runs at compile time ✓
var state = 0;                                 // NOT exported ✗
print("loading helpers");                      // NOT executed ✗
```

---

## The Gameplan (ordered)

### Step 1 — Fix SymbolTree root tree bug *(tiny, isolated)*
In `staged_forest::resolve_symbol_deps()`, skip generating SymbolTree deps for the root
tree. One conditional. The root tree is runtime code — its symbol references are resolved
by hoisting, not ordering. Only non-root (meta child) trees need SymbolTree deps.
This also eliminates the circular import deadlock risk.

### Step 2 — Parser: dot-access expressions *(isolated, no semantic change)*
Add `foo.bar` and `foo.bar(args)` to the expression grammar. The `Dot` token already
exists. New AST nodes: `MetaExpr::DotAccess { object, field }` and
`MetaExpr::DotCall { object, method, args }`. No runtime changes yet.

### Step 3 — Parser: updated import syntax *(isolated)*
Change `import util;` → `import "util";` (string path). Parse all three forms:

```
import "path";                        // Import::Qualified { path }
import "path" as alias;               // Import::Aliased   { path, alias }
import { name1, name2 } from "path";  // Import::Selective { names, path }
```

Update `MetaStmt::Import`, `StagedStmt::Import`, and all downstream match arms.

### Step 4 — Multi-file loader *(new module, no staging changes yet)*
A function `load_compilation_unit(entry: PathBuf) -> Vec<(PathBuf, MetaAst, FileRole)>`
where `FileRole` is `Entry | AutoScope | Explicit`. It:

1. Parses the entry file
2. Globs sibling `.cx` files in the same directory → `AutoScope` role
3. Resolves explicit `import "path"` directives → `Explicit` role
4. Recurses for transitive imports (cycle detection on file paths, not symbols)

Purely I/O + parsing. Nothing staged yet.

### Step 5 — Multi-file staging *(extend meta_stager)*
Stage all files from the loader into one `StagedForest`. Rules:

- Entry file's tree → `root_id`; all top-level statements staged normally
- `AutoScope` and `Explicit` files → same rule: stage `FnDecl`, `StructDecl`,
  and `MetaBlock` statements only; **skip** `VarDecl`, `ExprStmt`, and `Print`
- Meta blocks in any file produce child meta trees in the same forest as always
- No inherent ordering between runtime sibling trees (hoisting handles it)

### Step 6 — Namespace objects at runtime *(runtime env)*
For each `Explicit` import, after meta-processing, create a namespace value in the
runtime env — a record where keys are the file's exported names and values are the
functions/vars. `helpers.greet(x)` resolves via dot-access on the `helpers` record.

- `import "helpers"` → env["helpers"] = { greet: fn, ... }
- `import "helpers" as h` → env["h"] = { greet: fn, ... }
- `import { greet } from "helpers"` → env["greet"] = fn
- Same-dir `AutoScope` files → symbols go directly into the flat env (no namespace wrapper)

### Step 7 — Wire into the compiler entry point
`main.rs` and `script_integration.rs` call the loader before staging. The test harness
passes the source dir so sibling discovery works correctly.

### Step 8 — Register module tests