# Module System

## Core Philosophy

The file is the module. No declaration steps, no registration, no magic.
Imports tell the compiler where to look for symbols — they are search
directives, not hard dependency edges. The compilation unit is treated
as a single flat universe of symbols.

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

---

## Import Execution Semantics

When a file is imported (whether via explicit `import` or same-dir auto-scope):

- **Function and type declarations** (`fn`, `struct`) — collected and available in the importing scope
- **Meta blocks** (`meta { }`) — run at compile time, same as if the meta block were in the entry file
- **Variables** (`var`) — not exported; variables represent mutable state that should not leak across file boundaries
- **Top-level imperative code** (expression statements, `print`, bare function calls) — not executed

Only the entry file's top-level imperative code runs at runtime. This preserves test
isolation, prevents surprise side effects from imports, and is consistent with the
principle that meta is a compile-time concern while runtime execution belongs to the
program entry point.

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

## Compiler Resolution Model

Resolution is a two-pass process:

1. **Collection pass** — all declarations across all files in the
   compilation unit are gathered into a single symbol universe.
2. **Resolution pass** — all references are resolved against that
   universe. Import statements narrow the search space for this pass.

This means:
- Files can reference symbols defined in files not yet processed
- Circular symbol references are allowed (A references B, B references A)
- Circular imports (A imports B, B imports A) are allowed since
  imports are not dependency edges — they are hints
- A struct containing itself by value is a type system error, not an
  import error

### Integration with the StagedForest

The compiler's `StagedForest` orders meta trees using Kahn's topological
sort over `ProcessDependency` edges. The `SymbolTree` dependency type
tracks which tree provides a symbol that another tree consumes — this is
correct for **meta-time** ordering (a meta block that generates `fn greet`
must run before any tree that uses `greet` at meta-time).

For **runtime** symbols from imported files, `SymbolTree` deps do not
create ordering constraints. All imported files are merged into the root
tree's runtime AST as siblings; their ordering is handled by function
hoisting, not topological sort.

This means circular imports at the runtime level are always safe. A circular
dependency where a meta block in A depends on a meta block in B which depends
on A's meta output is still caught as a genuine cycle.

---

## Meta and Imports

Meta blocks interact with the module system as follows:

- `typeof(name)` in a meta block works across file boundaries — the type
  of `name` is resolved from the full compilation unit before any meta block runs.
- `gen fn foo() { ... }` in one file generating a symbol used in another
  file is handled by the existing `MetaTree` dependency ordering, provided
  both files are in the same forest.
- A meta block in file A can use a function defined in file B's meta block,
  provided the symbol dependency ordering resolves correctly (via `MetaTree`
  and `SymbolTree` deps together).

---

## Visibility

Symbols are exported by default. Private visibility is opt-in and is not
required for basic use.

---

## Beginner Experience

A beginner writing a small project never needs to know most of this:

- Put files in the same directory → they work together automatically
- Need something from another directory → `import "that/directory"`
- Name collision → add an alias

That is the entire mental model for 90% of use cases.

---

## What Was Deliberately Left Out

| Feature                                  | Reason Omitted                                            |
| ---------------------------------------- | --------------------------------------------------------- |
| Explicit module declaration (`mod`)      | Solves problems beginners don't have; add later if needed |
| Namespace independent of file (C# style) | Confuses beginners; complicates compiler                  |
| Unqualified imports by default           | Causes name collision confusion                           |
| Forced circular import ban               | Unnecessary given two-pass resolution model               |
