# Package Manager: implementation plan

[Package Manager.md](Package%20Manager.md) is the design. This is the order it gets built in and what "done" means at each step.

One rule shapes the ordering: **the registry is the easy part and it is the part that looks like progress.** A `cx` that builds a two-package tree over `path` dependencies has solved everything hard — the compilation unit, the boundary, the artifact, the cache. Fetching tarballs over HTTP after that is a week. Every milestone below is therefore chosen to force a hard question early and defer an easy one.

A milestone is done when its criteria hold *and* a fixture in `tests/` covers each one. The suite is the completion criterion; prose here is what the fixture is checking.

## 0. The driver exists

`cx/` beside `bootstrap/`, a dune executable linking `bootstrap` as a library. No manifest, no resolution: `cx run <file>` does what `bin/main.exe` does today, through the library rather than the binary.

This milestone exists to prove the seam. `Pipeline.compile` already returns `(Ast.cps_stmt list, Diagnostic.error list) result`, so diagnostics cross as data and `Render` stays presentation — if that turns out to be false, it is much cheaper to learn here than in milestone 3.

**Done when**

- `cx run` and `bin/main.exe` produce identical output for every fixture in `tests/`.
- `cx` never shells out to `cronyxc`, and no diagnostic reaches the user as a captured string.
- The `--dump-*` flags work through `cx`, since they are the only debugging tool the compiler has.

## 1. The manifest

`cronyx.toml` parses into a typed record: `name`, `version`, `cronyx`, and `[dependencies]` restricted to `{ path = … }`. Nothing else in the schema is read yet, and an unknown key is a diagnostic rather than a silent skip — a manifest that quietly ignores what it does not understand is how a typo becomes a support burden.

The TOML parser is a coin flip between vendoring `otoml` and writing one. `bootstrap` currently declares `(depends ocaml)` and nothing else; that property is worth knowing you are spending, and it is not worth an argument.

`cx new <name>` writes the skeleton: manifest, `src/main.cx`, `.gitignore` naming `target/`.

**Done when**

- A manifest missing `name` or `version`, carrying an unknown key, or naming a malformed version fails with a `Diagnostic` carrying a span into the TOML.
- `cx new` produces a package that `cx run` executes.
- Version requirements parse to the table in the design doc, including the `0.y.z` and `0.0.z` cases, which are where hand-rolled SemVer implementations go wrong.

## 2. The package boundary

The loader gains two parameters. Neither changes what it does; both change what it is allowed to reach.

- **A root.** An `import` that resolves outside the package root is an error naming both the import and the root. Inside the root, `import "../other/thing"` stays legal — a package is a set of files under one directory.
- **A dependency map**, `name → directory`, supplied by `cx`. `import "http/client"` consults the map before the filesystem; a name absent from the map is an unresolved-dependency diagnostic, not a file-not-found.

This is the milestone that makes the design real. Until the boundary is enforced, `import "../../../stdlib/…"` keeps working and the package model is advisory.

**Done when**

- A fixture importing above its package root fails with the boundary diagnostic.
- A two-package tree over `path` deps compiles and runs, the dependency reached only by name.
- No fixture in `tests/` reaches outside its own tree; the ones that do today are migrated in this change, not after it.
- `stdlib` resolves from the toolchain root rather than by relative path, so `import "std/…"` works from any directory.

## 3. Separate compilation

The point of the project and the item [Package Manager.md](Package%20Manager.md) calls "a design rather than a task". A dependency stops being source the consumer recompiles and becomes an artifact it loads.

The format is settled — serialize the compiler's own types, tag with the compiler version, key the cache on the tag, rebuild everything when the types change.

**What an artifact holds today** is the package's declarations after loading, mangled under the package's own name, plus the names each of its units exports. It is not metaprocessed: which copy of a template exists, and which declarations a `meta` block reaches, is decided by the program that uses the package, so the walk runs once over the linked program, from the package root. It stops before the checker: a consumer typechecks and monomorphizes the whole graph at once, which is what lets a generic from a dependency be instantiated at a type the dependency never saw. Shipping *typed* IR — so a consumer need not re-check a dependency's bodies — is the next step and is what makes the artifact an interface rather than a shortcut.

Two consequences of stopping there, both worth knowing before they are discovered:

- **A `meta` block runs when the program is put together, not when its package is compiled.** The walk covers the linked graph, so a `meta` block reaches a dependency's declarations like any others, and a dependency's `meta` blocks run again on every run of every program that reaches them.
- **The standard library is embedded, not linked.** `stdlib` is not compiled to an artifact, so each package that imports it carries what it used, and the link keeps the first declaration of each name. Compiling `std` like any other package retires that.

**Done when**

- A dependency compiled once and consumed from cache produces output identical to the same tree compiled from source. *(`cx/test/packages`, every fixture built cold and then again over its own artifacts.)*
- A generic exported by a dependency is instantiated at a type the dependency never saw. *(`generic_dep`.)*
- Two packages declaring the same unit name link without collision. *(`same_unit_name`.)*
- Two dependencies defining an overlapping impl are rejected, with both sites in the diagnostic. *(`overlapping_impls`.)*
- Deleting `target/` changes nothing but the wall clock. *(The suite deletes every `target/` before each fixture.)*

## 4. The cache

Content-addressed, keyed on an input hash covering: the compiler version, every source file, the manifest, the feature set, the profile, every path an `embed` read, and each dependency's artifact hash.

`embed` resolves in `loader.ml` and `readfile` runs in `builtins.ml`; both record what they read in `Inputs` rather than at the call sites, so that a third way to read a file cannot forget to. Only what is read while the artifact is built lands in it, and that is `embed`'s: the artifact is not metaprocessed, so a `meta` block's `readfile` runs when the linked program is walked and reads the file again on every run.

An artifact carries every path it read and what that path hashed to, so freshness is a question about content rather than about a clock: touching a file changes nothing, editing one rebuilds the package that read it and everything above it. The paths are recorded rather than derived from the manifest, since nothing in the manifest names what a program embeds.

A build runs from the package root, so every path an artifact carries is relative to it and two copies of one tree compile to the same bytes.

**Done when**

- A second `cx build` with no change does no compiler work. *(`cache/unchanged`, which asserts the compiled list is empty.)*
- Changing a file a `meta` block reads rebuilds nothing, and the next run reads it again. *(`cache/meta changed`, over `reads_data`.)*
- Changing the compiler version invalidates everything. *(`cache/version changed`.)*
- Two builds of the same tree in different directories produce byte-identical artifacts. *(Built from the package root; verified by hand across two locations.)*

**Todo, left by this milestone**

- **Nothing bounds a `meta` block.** It can loop forever or eat the machine. Out of scope for the cache, but it is the other half of "the environment the build sees is empty".
- **The artifact stops before the checker.** A consumer re-checks a dependency's bodies, so the cache saves parsing and loading but not metaprocessing or inference. Turning the artifact into a real interface needs five things that do not exist: generalized schemes for exported names (generalization happens in `infer_stmt`, not `hoist`), `Desugar`'s whole-program `handler` and variadic tables, a serializable snapshot of `Typecheck`'s global tables, the `Registry` entries a dependency registered, and the prelude split out of package compilation so it is not carried by every artifact. Worth doing when `pub` arrives or when re-checking is measurably the slow part; neither is true yet.
- **The standard library is embedded per package.** Compiling `std` like any other package retires both that and the first-wins dedup at link.

## 5. Toolchains and dispatch

`~/.cronyx/toolchains/<version>/`, the forward-only `bin/cx` copy, and the two-phase dispatch: exec on the root manifest's floor, resolve, exec once more if the graph raised it.

`cx toolchain install` and `cx toolchain list` are in this milestone rather than deferred, because the tool that picks a compiler has to be able to install one.

**Done when**

- A package pinned to a version the machine lacks installs it and builds, with no prior step. **Half done.** Dispatch finds an installed toolchain and hands the job to it; there is no download, so a version the machine lacks is a diagnostic naming it and where it would come from rather than a fetch. `cx toolchain install <version> <binary>` installs from a file, which is what a release would put there.
- Installing an older toolchain leaves `bin/cx` alone. *(`cx toolchain install` reports which of the two happened.)*
- A `cx` too old to satisfy a manifest fails naming the version and where to get it, never with a parse error. *(`preamble` cases, including a manifest carrying an `edition`, an inline table, and a `[profile.release]` this compiler knows nothing about.)*
- Dispatch execs at most twice. *(`CRONYX_DISPATCHED` is set across the exec: a toolchain installed under a version it does not report stops the job rather than passing it back.)* The lockfile is not what bounds it yet — the second floor is the maximum over the manifests the graph reaches, read with the frozen reader, and it becomes the lockfile's answer in the next milestone.

**Todo, left by this milestone**

- **No download.** `toolchains.cronyx.dev` is a URL in a diagnostic and nothing else. The seam is `Toolchain_store.install`, which takes a file today and would take a fetched-and-verified one instead; the checksum belongs there with it.
- **No `default` toolchain outside a package.** `~/.cronyx/config.toml`'s `default = "…"` is in the design and not in the code; outside a package `cx` is simply whichever one ran.

## 6. Resolution and the lockfile

`cronyx.lock` written deterministically — sorted, stable, no incidental ordering — because the alternative is diff churn in every user's repository forever. `cronyx` resolves as a lower-bound-only node: the maximum over the graph, which is the version dispatch hands to and therefore the one to pin.

**Not PubGrub, yet.** PubGrub chooses between candidate versions, and with `path` dependencies there is nothing to choose: a package is whatever version its own manifest names. What resolution has to catch today is a graph that disagrees with itself — two paths reaching one name at two versions — and a compiler floor nothing on this machine reaches. Both are reported in the shape the design doc asks for. PubGrub arrives with the registry, which is where a name first has more than one candidate.

**Done when**

- A conflict renders the requirement chain in the shape the design doc shows. *(`version_conflict`, where two paths reach `alpha` at 0.1.0 and 0.2.0.)*
- A floor no released compiler reaches is reported as an unsatisfiable requirement, in the same shape as any other. *(`needs_future_compiler`.)* In the CLI, dispatch answers first with the more actionable message, naming where to get the toolchain; resolution's is what a caller past dispatch sees.
- The same graph resolves identically on two machines, and re-resolving rewrites the lockfile byte-for-byte. *(`lock/byte-identical when written again`; the paths in it are relative to the root, as artifacts are.)*
- `--locked` fails rather than writing; `--locked` with no lockfile is an error rather than a generation. *(`lock/absent under --locked`, `lock/holds under --locked`.)*
- `cx build` reads no index — there is none to read, and the lockfile is written before anything is compiled.

**Todo, left by this milestone**

- **`--offline` is inert.** It parses and it is carried through `Build.mode`, and there is no network for it to refuse. It becomes real with the registry, and the point of shipping it now is that `--frozen` means both axes from the start rather than being widened later.
- **No `cx add` or `cx update`.** Both are about a registry: `add` writes a requirement and re-resolves, `update` moves a pin. Neither has anything to do until there are versions to pick.
- **The lockfile records no checksum.** A `path` dependency has no tarball to hash. The field arrives with the registry, alongside the `source = "registry+…"` it belongs to.

## 7. The registry

**A directory, not a server.** A registry is reached through a root: an index saying which versions exist and what each requires, and a store holding the archives. That root is a directory today and a URL when there is something to talk to. Standing up a server is deployment rather than language work, and everything that makes a registry trustworthy — the index, the checksum, the cache, immutability, yanks — is on the client and is real either way. `CRONYX_REGISTRY` points at it.

The archive is ours rather than a tarball, for the same reason and only until there is a transport: entries sorted, no timestamps, no modes, so two packings of one tree are the same bytes and a checksum means something.

**Done when**

- A published package resolves, downloads, verifies, and builds on a machine that has never seen it. *(`registry/resolves, fetches, verifies and builds`; `registry/takes the newest satisfying version` pins that `greet = "1.0"` chose 1.1.0 over 1.0.0.)*
- Re-publishing an existing version fails. *(`registry/publish is once only`.)*
- A yanked version still resolves for a lockfile that already selected it. *(`registry/a yank leaves a pinned version alone`, and `…is skipped by a new resolution` for the other half.)*
- A tarball whose checksum does not match the lockfile is an error before anything is compiled. *(`registry/a bad checksum stops the build`.)*
- Publishing a package with a bare `path` dep fails. *(`registry/publishing a path dependency fails`.)*

**Todo, left by this milestone**

- **No transport.** `Registry_source.root` returns a directory. An HTTP client, a sparse index over the same files, and `PUT /api/v1/crates/new` replace it without the client above changing.
- **Still not PubGrub.** Resolution now has candidates to choose between, and it chooses: the newest version satisfying every requirement anyone made of that name, re-choosing when a later requirement rules out an earlier choice. It reports a conflict with every requirement and who made it, which is the diagnostic PubGrub was wanted for; what it does not do is derive the incompatibility that explains *why* no version can work. That derivation is the upgrade, and it is worth making when a real graph produces a conflict this cannot explain.
- **No `cx add` or `cx update`.** Both are small now that resolution takes requirements: `add` writes one into the manifest and re-resolves, `update` moves a pin.
- **No `include` / `exclude` at pack time.** `cx publish` packs the directory minus `target/`; the manifest keys are specified and not read.
- **No `yank` subcommand.** The index field is read and honoured; setting it is a registry operation with no client for it yet.

## What is not in the plan

**`cx test`.** Built — see [Testing](Testing.md). What this entry said the language could not express, it now can: `@test` is an attribute, a failed assertion is `Assertion::failed`, and `final ctl` gives per-test isolation without a process boundary. It was never blocked on anything in this plan and it still blocks nothing.

**Features.** They arrive with the registry and not before; a feature is not observable in a tree of `path` dependencies. The design doc's §Features still contains a contradiction to resolve first — a feature set cannot both be part of the resolution key and be unioned into a single build — and the correct model is a fixpoint over version resolution and feature unification, because enabling a feature can add an edge that adds a package that requests features.

**Codegen.** `cx build` emits nothing executable and `cx run` interprets. When a backend lands, `cx build` writes `target/<profile>/<name>` and nothing in this plan changes.

**Workspaces, profiles beyond `checks`, `[build-dependencies]`, `[dev-dependencies]`.** Each lands with the feature that needs it.
