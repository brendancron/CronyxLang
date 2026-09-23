# Internal documentation

Design notes, plans, and rationale for the Cronyx compilers themselves.

This is separate from `docs/`, which is the Docusaurus site published for language *users*. Nothing here ships. Write for the person implementing the compiler — including future you — and prefer recording *why* a decision was made over restating what the code does.

| Document                                                     | Subject                                                               |
| ------------------------------------------------------------ | --------------------------------------------------------------------- |
| [Architecture.md](Architecture.md)                           | `bootstrap` pipeline, a heading per pass                              |
| [Type System.md](Type%20System.md)                           | Type system and type checking for `bootstrap` (OCaml)                 |
| [Algebraic Effects.md](Algebraic%20Effects.md)               | Effect rows and the selective CPS pass                                |
| [Row Polymorphism.md](Row%20Polymorphism.md)                 | Abstracting over the effects a callback performs                      |
| [Continuations and Tasks.md](Continuations%20and%20Tasks.md) | Why a continuation is pure and a task is not, and what a scheduler owes to it |
| [Async.md](Async.md)                                         | The one operation `async` declares, and why a promise is data         |
| [Data Structures.md](Data%20Structures.md)                   | The datatypes and how each is used                                    |
| [Collection Literals.md](Collection%20Literals.md)           | How `[...]` picks a collection type                                   |
| [Elaboration.md](Elaboration.md)                             | Type-directed resolution of operators, indexing, and literals         |
| [Static vs Dynamic Invocation.md](Static%20vs%20Dynamic%20Invocation.md) | What is resolved at compile time, and what a trait object defers to run time |
| [Static Params.md](Static%20Params.md)                   | `<>` parameters, and why they are not just generics                   |
| [Diagnostics.md](Diagnostics.md)                             | Spans, and why a frame cannot render half-drawn                       |
| [Modules.md](Modules.md)                                     | `import`, and why several files become one program                    |
| [Package Manager.md](Package%20Manager.md)                   | `cx`, packages, resolution, and where the module boundary hardens     |
| [Package Manager Plan.md](Package%20Manager%20Plan.md)       | The order `cx` gets built in, and what "done" means at each step      |
| [Metaprocessing.md](Metaprocessing.md)                       | `meta` and `gen`, and compilation calling itself                      |
| [Reify.md](Reify.md)                                         | Turning a compile-time value back into syntax                         |
| [Attributes.md](Attributes.md)                               | `@name(…)` on a field or a variant, and why it cannot reach runtime   |
| [Testing.md](Testing.md)                                     | `cx test`, and why a failed assertion is an effect                    |
| [Attributes and Test Frameworks.md](Attributes%20and%20Test%20Frameworks.md) | Attributes as values, and a test runner written in Cronyx rather than in the compiler |
| [TODO.md](TODO.md)                                           | Decisions deferred deliberately, and what each one is waiting on      |
| [GADT Refinement.md](GADT%20Refinement.md)                   | Refining a type parameter in a match arm, and the choice of how       |
