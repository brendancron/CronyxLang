 # Package Manager

Status: **not built.** No manifest, no resolver, no registry, no `cx` driver. This document is the plan.

The tool ships alongside the compiler and is the boundary where the [Modules](Modules.md) design ends: cycles are legal *inside* a package and rejected *between* them, and an interface is what crosses. Everything else here follows from that one line.

## What the tool is called and what it does

`cx`. One binary, subcommands. The compiler is a library it links against, not a program it shells out to — a `cx build` that fork/execs the compiler pays the OCaml startup cost per invocation and loses structured diagnostics to a pipe. `cx` may exec *once*, at startup, to hand the job to a different toolchain's `cx` (see [Toolchains](#toolchains-cx-installs-its-own-compiler)); after that the compiler is a library for the rest of the run.

Eight subcommands cover the whole model. Each one is small; extra flags earn their place the same way a comment does.

```
cx new <name>            create a package skeleton
cx build                 resolve, fetch, check, cache
cx run [-- args…]        build then execute the entry
cx test [filter]         run the package's @test functions
cx add <pkg>[@<req>]     record a dependency, resolve, lock
cx update [pkg…]         move pins to the newest versions that fit
cx publish               upload to a registry
cx toolchain <cmd>       install, list, and pin compiler versions
```

`toolchain` is in the list rather than deferred because dispatch depends on it: the tool that picks a compiler must also be able to install one.

`why`, `vendor`, `fmt`, `doc`, `bench`, `check`, `clean`, `search`, `login`, `yank`, and `tree` follow later. None of them change the model. Two are load-bearing when they land: `why <pkg>` prints the requirement chain that selected a version, which is the only way to learn which dependency raised the compiler floor; and `vendor` is what `--offline` needs on a machine with a cold cache.

## The tool lives in the compiler's repo

`cx` is a sibling of `bootstrap/` in this repository, not a separate one. The rule from the section above — the compiler is a library the tool links against — makes the seam a build-graph edge, not a network of pinned repos. Splitting them would mean a version-pinned dependency between two trees the same people own, which is friction with no payoff: every compiler change that touches a public type would need a coordinated two-repo pull request.

```
CronyxLang/
  bootstrap/              the compiler: library + `cronyxc` binary
  cx/                      the package manager, links `bootstrap` as a library
  stdlib/                  shared
  tests/                   the compiler's own fixtures, run by `dune test`
  internal-docs/
```

Three consequences.

- **One release ships one artifact.** The toolchain tarball carries `cronyxc` and `cx` together; a split repo means two release trains that must stay in sync anyway, and every mismatch is a bug report.
- **One suite of fixtures, and `cx` is held to it.** `tests/` is the compiler's, run by `dune test`; `scripts/cx-parity.sh` then requires `cx run` to agree with `bootstrap` on every one of them, both streams and the exit code. That is what a split repo could not keep honest. `cx test` is a different thing entirely — the in-language framework a package author uses, see [Testing](Testing.md) — and the two share a name rather than a mechanism.
- **The Cargo / Rust split is historical.** Cargo predates `rustup` and predates being part of the release train; the seam is one the Rust project has spent effort papering over rather than defending. Go, Deno, Bun, and Zig keep the tool in-tree, and none regret it.

**When to split.** `cx` self-hosts in Cronyx *and* has enough users that its release cadence needs to decouple from the compiler's. Neither is close, and the split at that point is a mechanical `git filter-repo`, not a design change.

## Toolchains: `cx` installs its own compiler

**There is no shim.** Every toolchain ships a complete `cx`, and `~/.cronyx/bin/cx` is a copy of one of them. On startup `cx` walks up for `cronyx.toml`, reads the toolchain the package requires, and if that is not the version it happens to be, execs that toolchain's `cx` with the original argv. Dispatch is a mode of the full tool, not a separate program.

This is Go's shape. The `rustup` split — a tiny stable launcher in front of a moving toolchain — buys one failure that has to be apologized for: a toolchain needing a launcher capability the installed launcher lacks, repaired by hand with a self-update command. A design whose stated failure mode is manual repair of the component that was supposed to never need repair has the seam in the wrong place. Here the seam is the dispatch preamble alone, and it heals on its own: installing any newer toolchain refreshes `~/.cronyx/bin/cx`.

What this buys, in order of importance:

- **A fresh clone builds.** A repo pinned to `cronyx = "0.1.1"` on a machine that has never seen 0.1.1 downloads it and runs. There is no "install the right compiler first" step because the tool doing the build is the tool that installs compilers.
- **No second release train.** A package-manager feature ships in a toolchain like everything else. There is no version of `cx` that is separately installed, separately updated, or separately reported in a bug.
- **CI is one line.** `curl https://cronyx.dev/install | sh` gives a machine a toolchain, and every subsequent build resolves and downloads whichever one it needs. There is no matrix of preinstalled compiler versions to maintain.

```
~/.cronyx/
  bin/cx                              a copy of one toolchain's cx, on $PATH
  toolchains/
    0.1.4/
      bin/cx                          the whole tool: dispatch, resolver, compiler
      bin/cronyxc                     the bare compiler driver
      lib/…                           prelude and stdlib for this version
    0.2.0/
      …
  registry/                           the cache from the previous section
```

**`bin/cx` only ever moves forward.** Installing a toolchain overwrites it when the new version is higher, and leaves it alone when it is lower. Without that rule, `cx toolchain install 0.1.0` to reproduce an old bug would leave the dispatcher too old to read a current package.

**The dispatch preamble is frozen grammar.** `cx` must be able to find the required version in a manifest written by a compiler released years after it. So `cronyx = "…"` is a top-level string under `[package]`, never nested, never conditional, never computed, and that shape does not change. A `cx` that reads the field and cannot satisfy it fails naming the version and where to get it — never with a parse error.

**Dispatch runs in two phases**, because the graph can raise the floor above the root's:

1. Find the package root, read `[package].cronyx`, and exec that toolchain if it is not the running one.
2. Resolve. If the resolved compiler version exceeds the running one, install it, exec once more, and stop — the lockfile now pins the answer, so the second exec cannot cascade.

**`cronyx` is a node in the resolution graph, not a special field.** It resolves by the same machinery as every other package, with one restriction: it can only ever be a **lower bound**. `cronyx = "0.1.1"` means `>=0.1.1` and never `^0.1.1`. Resolution takes the maximum over the graph and the lockfile pins the exact version.

The restriction is the whole design. A package able to express an *upper* bound on the compiler makes the ecosystem unbuildable the first time someone publishes `cronyx = "<2"` and stops maintaining it. Cargo's `rust-version` is a minimum only for exactly this reason, and it is the one place to copy Cargo without hesitation.

Two consequences follow.

- **A toolchain requirement cannot conflict.** The maximum satisfies every floor by construction, so the only failure is a floor no released version reaches — reported as an unsatisfiable requirement, in the same shape as any other. There is no second diagnostic to write.
- **`cx why cronyx` is how a user learns why the floor moved.** The requirement chain is the answer to "which dependency dragged my compiler forward", and without it that question has no answer at all.

A separate `edition` field for language dialects (the way Rust distinguishes 2018 / 2021 / 2024 source) is *not* shipped: there is one edition, so the field would always carry the same value. It arrives when a second edition does.

**Outside a package**, `cx` uses the toolchain it belongs to, or the one named by `~/.cronyx/config.toml`'s `default = "…"`. `cx toolchain install <version>` and `cx toolchain list` handle the manual side; the automatic side is what carries the weight.

## A package is a directory with a manifest

```
mypkg/
  cronyx.toml              the manifest
  cronyx.lock              the resolved graph, generated
  src/
    main.cx                the entry, for a binary
    lib.cx                 the root module, for a library
  tests/
    …                      .cx / .txt fixtures, the way this repo already runs them
  target/                  build output, in .gitignore
```

`cronyx.toml`, not `cronyx.json`: comments matter in a file humans edit, and JSON has none. Not `Cronyx.toml` capitalised — the file is code, not a title.

```toml
[package]
name    = "mypkg"
version = "0.3.1"
cronyx  = "0.1.1"         # minimum compiler toolchain; `cx` installs it if missing

[dependencies]
http    = "1.4"            # ^1.4 by convention, per SemVer
json    = { version = "0.9", features = ["derive"] }
tui     = { git = "https://…", rev = "abc123" }
local   = { path = "../local" }
```

**This is the MVP surface.** `[dev-dependencies]`, `[build-dependencies]`, `[features]`, `[[bin]]`, `[lib]` and `[workspace]` each land with the feature that needs them — the sections below describe those additions. A key earns its place in `[package]` the way a comment earns its place in code: only when omitting it costs the reader something.

Two things the manifest deliberately will *not* grow, even when the rest does:

- **No `[workspace]` in the leaf.** A workspace is a separate root manifest that lists members. Repeating it in every leaf is where Cargo grew a class of confusing errors.
- **No `[patch]` at the leaf either.** Overrides live in the workspace or user config, never in a manifest that ships to a registry.

## The standard library ships with the toolchain

`stdlib` is **not a package**. It is part of the toolchain tarball, it has no manifest, no version of its own, and no entry in the lockfile. `import "std/…"` resolves against the running toolchain's root — never the filesystem, never a registry — which is what retires the `import "../../../stdlib/…"` shape the tests use today.

The consequences are worth stating, because two of them are costs.

- **`[package].cronyx` gates both.** One number is the compiler floor and the standard-library floor, so a package that needs a new `stdlib` function raises the same field it would raise for a new language feature.
- **A `stdlib` fix requires a compiler release.** There is no route to shipping a library patch on its own cadence. This is the price of the version being implicit, and it is worth paying while the library is small enough that a compiler release is the natural unit anyway.
- **`stdlib` cannot depend on a registry package.** It is compiled by the toolchain that contains it, before any resolution has happened.

If the standard library ever needs to move independently, it becomes a normal package with a normal version, and every rule below applies to it unchanged. Nothing here forecloses that.

## The compilation unit

**A package is a compilation unit.** One `Type_mono` run, one prelude, one global name space per package. This is what makes cycles inside a package legal — the [Modules](Modules.md) design already turns each unit's declarations into `unit__name` and concatenates. A package is the largest tree that goes through the pipeline together.

**A dependency is compiled separately** and consumed as an *interface plus a monomorphizable body*. `Type_mono` runs on typed IR; a compiled dependency must therefore ship the typed body of every exported generic, the way a Rust rlib ships generic MIR. Non-generic bodies can ship as their post-CPS form. Nothing about this decision is free — it is the item [Modules.md](Modules.md) called out as "a design rather than a task", and it is the largest thing this project buys.

**Cycles between packages are rejected at resolution**, before any compilation. The resolver's graph is a DAG or the tool refuses. This is the second half of what `import "../../../stdlib/…"` currently sidesteps: relative paths reach anywhere the filesystem does, and a package boundary is a name the tool understands rather than a path it walks.

**Path imports across package boundaries are forbidden.** Inside a package, `import "../other/thing"` stays legal — a package is a set of files under one root. Reaching *outside* that root goes through `[dependencies]` and a name, so the resolver sees it. This is the one rule that turns Modules' informal boundary into an enforceable one.

## Versions, requirements, and resolution

Semantic versioning, unmodified. `major.minor.patch`, with `-pre` and `+build` suffixes read but not compared beyond pre-release ordering.

A requirement is a *set* of acceptable versions. The manifest DSL is Cargo's, chosen for reader recognition:

| Written | Means |
|---|---|
| `"1.4"` or `"^1.4"` | `>=1.4.0, <2.0.0`, the default |
| `"~1.4"` | `>=1.4.0, <1.5.0` |
| `"=1.4.2"` | exactly that version |
| `">=1, <2"` | a raw range |
| `"0.4"` | `>=0.4.0, <0.5.0` — for a `0.y.z` package, `y` is treated as major, the SemVer convention |
| `"0.0.3"` | `>=0.0.3, <0.0.4` — at `0.0.z`, every bump is a breaking change |

Resolution is one function: given the manifest's requirements and a registry index, produce a set `{ package → version }` satisfying every requirement, with the constraint that a single graph carries **one version per package name** for each *public* dependency and *at most two majors* for private ones. This is stricter than Cargo (which allows any number of majors) and is what lets a type from one package flow through another without confusion. It costs the ability to have five versions of the same library linked at once; the language does not want that either.

**MVS or PubGrub.** Go's Minimum Version Selection is simpler to explain, produces reproducible builds without a lockfile, and eliminates the class of "my machine picked a different patch" bugs. PubGrub gives better diagnostics ("A wants B ^1, C wants B ^2, so no version of B works"). The initial resolver is PubGrub — the diagnostic quality is worth the implementation cost, and the class of user error the resolver reports on is exactly the class we want to be precise about.

**The lockfile is authoritative for `build`.** A version in `cronyx.lock` is kept for as long as it satisfies every requirement the graph now makes of its name, so a newer release changes nothing about a build that has already locked an older one. `cx build`, `run` and `test` resolve only what the lock cannot answer: a dependency added since, or one whose requirement has moved so that its pin no longer fits. One removed is not reached from the manifest and drops out. A package that moves can take its own dependencies with it, when what it moved to requires versions their pins do not satisfy; nothing else moves. This is the invariant users depend on: a green build stays green, and the lockfile changes only when the manifest did.

A pin is a preference, not a constraint: the resolver tries it first and falls back to the newest that fits, so a requirement edited past the pin is followed by the next build rather than refused, and an edited manifest never needs a second command to build. This is Cargo's rule.

`cx update` is the only path that moves a pin that still fits. With no names it resolves as if there were no lockfile; with names it unpins those and keeps the rest, which then move only by the rule above. It prints what moved, one `Updated greet 0.1.0 -> 0.1.1` per package, or `Nothing to update.` `--locked` is then an assertion about the manifest — it fails exactly when the manifest has moved away from the lock — and `cx update` refuses it, since changing the lock is all it does.

## The lockfile

`cronyx.lock`, generated, checked in for **binaries**, checked in for **libraries too** — the Rust convention of omitting it for libraries saves nothing and makes bug reports irreproducible.

```toml
[[package]]
name = "mypkg"
version = "0.3.1"
dependencies = ["http 1.4.7", "json 0.9.2"]

[[package]]
name = "http"
version = "1.4.7"
source = "registry+https://packages.cronyx.dev"
checksum = "blake2b:…"
dependencies = ["bytes 0.1.4"]
```

`checksum` covers the source tarball, not the compiled artifact. Binary caches are a separate concern (below) and have their own hash. A version the lockfile pins is verified against the checksum recorded here, not against whatever the index says today: an index that changed its mind about a published version is exactly what the lock exists to catch, and a mismatch says which of the two it checked.

**A git dependency locks two hashes, not one.** The resolved commit is what `rev` names, but a commit is a name a server chooses and a rewritten history can reuse; the lockfile therefore also records a hash of the checked-out tree, and a checkout whose tree does not match is an error rather than a rebuild.

```toml
[[package]]
name = "tui"
version = "0.2.0"
source = "git+https://…?rev=abc123"
commit = "abc123…"
checksum = "blake2b:…"        # over the checked-out tree
```

**No schema-version field.** Cargo's lockfile carries `version = 4` because it has been migrated three times; a fresh format has nothing to migrate from. When the schema needs to change, the field arrives with the first change and starts at `1`.

## The registry

**One canonical registry** with a public HTTP API, served at `packages.cronyx.dev`. Third-party registries reachable by URL; the manifest names them:

```toml
[registries.internal]
index = "https://packages.corp.internal"

[dependencies]
sekrit = { version = "1", registry = "internal" }
```

The index is a **git repository of JSON files**, one file per package, sharded by name prefix. This is the design crates.io eventually moved away from (to a sparse HTTP protocol) because the git clone grew to gigabytes; a sparse HTTP endpoint over the same files is the design to start with. `cx` fetches only the files it needs.

Publishing is `PUT /api/v1/crates/new` with an API token and a tarball, the tarball's manifest signed by the token's account.

**A `path` dependency blocks publishing unless it also carries a `version`.** `{ path = "../local" }` means nothing to anyone who downloads the tarball, so the registry rejects it. `{ path = "../local", version = "0.2" }` publishes: the path is used locally, the version is what the published manifest records. The `cronyx.toml` inside the tarball is rewritten so that the dependency is `local = "0.2"`, since a consumer builds what it downloads and has no `../local`. Locally the package at the path must satisfy the version, or resolution reports it like any other conflict. This is Cargo's rule and the reason for it is the same.

**The tarball's contents are declared, not inferred.**

```toml
[package]
include = ["src/**/*.cx", "cronyx.toml", "README.md", "LICENSE"]
exclude = ["tests/fixtures/large/**"]
```

`include` wins where both appear. With neither, the default is the package root minus `target/`, minus `cronyx.lock` and the top-level `tests/`, and minus anything hidden, which is where VCS directories, ignore files and editor state live. An allowlist is the safer default to reach for, and a package that ships its `target/` once has already leaked whatever was in it. Neither key exists yet, and neither does reading what the VCS ignores; the default is all there is.

**What ships has been built.** `cx publish` unpacks the tarball into `target/package/<name>-<version>/` and builds it there before anything reaches the registry, so a package that does not compile — or compiles only because of a file the tarball leaves out, or depends on a version of a path dependency nobody has published — is refused rather than discovered downstream.

**No auto-yank on vulnerability.** A yanked version still resolves for a lockfile that already selected it — otherwise a security disclosure breaks every downstream build simultaneously, which is not the disclosure's intent. New resolutions skip yanked versions with a diagnostic: a `note:` on stderr naming the yanked version that would otherwise have been taken and the one that was.

## Caches, directories, offline

```
$XDG_CACHE_HOME/cronyx/
  registry/
    index/                 the sparse-fetched JSON, per-registry
    src/                   unpacked source, one directory per <name>-<version>
    bin/                   compiled artifacts, keyed by content hash
  git/
    checkouts/             git-source deps, per revision
```

`target/` is per-package, per-profile:

```
target/
  debug/                   the default profile
    build/                 build-script outputs
    deps/                  intermediate compiled units
  release/
```

**Offline is a first-class mode.** `cx build --offline` refuses network access and errors if the cache lacks something. The cache keeps the index entry of every release it fetched beside its source, so it has the shape of a registry and an offline resolution is the ordinary resolver pointed at it: nothing reads the registry, a pinned version still resolves, and a dependency never fetched is an error naming it. `cx build --frozen` additionally errors if the lockfile would need updating. Both are what CI wants; both are what a plane wants; the only way to reach that reliably is to make them modes, not the accidental effect of a warm cache.

## What `cx build` produces

**Nothing executable, for now.** The pipeline ends at the interpreter; there is no code generator, so there is no binary to emit. `cx build` resolves the graph, fetches sources, runs the compiler over every package, populates the artifact cache, and prints what it checked. `cx run` is the path that actually executes anything, and it runs the entry through the interpreter.

This is a statement about today, not a design position. When a backend lands, `cx build` writes `target/<profile>/<name>` and nothing else in this document changes — which is the reason to say the current behavior plainly instead of describing an output that does not exist.

## Profiles

Two by default: `debug` and `release`. A profile is a set of compiler flags:

```toml
[profile.debug]
checks = "all"             # bounds, overflow, effect assertions

[profile.release]
checks = "safety"          # bounds and overflow stay; assertion-style checks compile out
```

`opt` and `debug-info` are absent on purpose. Both name knobs on a code generator that does not exist, and a manifest key that silently does nothing is worse than one the tool rejects. They arrive with the backend.

Not four (`dev`, `release`, `test`, `bench`) — `test` and `bench` inherit from `debug` and `release` respectively, and the split only exists to let a user tune them separately, which nobody does. One rule.

## Features

A feature is a **compile-time flag** the manifest names. A dependency's feature set is part of the resolution key: if two paths through the graph ask for different features of `X`, the resolver unions them and compiles `X` once with the union. This is Cargo's model and it is the right one — the alternative (compile `X` twice) loses type identity across the graph.

```toml
[features]
default = ["std"]
std     = []
async   = ["dep:runtime"]  # pulls in an optional dep
serde   = ["dep:serde", "json?/serde"]   # forwards to a dep's own feature
```

Features are **additive**. A feature must not remove behavior, only add it; this is the invariant that lets union resolution be correct. A feature that turned an API off would silently break every consumer that expected it on. The tool cannot enforce additivity — it is a contract on the publisher — but the manifest schema makes the intent visible.

**No global features.** A workspace-level default that flips a feature in a transitive dep is how Cargo builds end up differing between `cargo build` at the leaf and `cargo build` at the root. Not shipped.

## Workspaces

A root manifest that lists members:

```toml
[workspace]
members = ["compiler", "runtime", "tools/*"]
resolver = "2"             # placeholder; there is only one resolver until there is a reason for a second
```

Every member shares one `cronyx.lock` and one `target/`. The workspace is where `[patch]` lives, where a `[profile.release]` override lives, and where cross-member deps write `{ path = "…" }` without version. A single `cx build` at the root builds every member.

The workspace is *not* a compilation unit. Each member is still one `Type_mono` run. What the workspace shares is resolution, caching, and the lockfile.

## Build scripts and metaprocessing

Cronyx already has `meta` blocks that run at compile time — they are the language's build scripts. A separate `build.cx` in the Rust sense would be a second mechanism doing the same job, which the [Modules](Modules.md) design's five decisions specifically rule out.

What the manifest *does* need is `[build-dependencies]`: packages available to `meta` blocks but not to runtime code. The distinction matters because a build-dep may itself pull in native code or heavy transitive deps that should not end up in the shipping binary.

A file `embed` reads participates in the build's input hash — anything read while a package is built is a build input, and rebuilding when it changes is the tool's job. A `meta` block's `readfile` is not one: a package's artifact is loaded and mangled but not metaprocessed, so its `meta` blocks run when the program using it is put together, and read the file again each time.

## Reproducibility

**One version per package per resolution** (above) is the largest source. The rest is a checklist:

1. **Timestamps are zeroed** in compiled artifacts. The one place a build embeds the wall clock is the one place two identical builds diverge.
2. **Paths in diagnostics are relative to the package root**, never absolute. `Ast.locate` already renders relative to the entry's directory; the tool extends that to *package* root.
3. **The environment the build sees is empty** unless the manifest names variables. A `meta` block that reads `$HOME` is a diagnostic.
4. **The compiler version is part of the lock**, and a mismatch installs the pinned toolchain rather than warning. See [Toolchains](#toolchains-cx-installs-its-own-compiler) — the lockfile records the exact `cronyx` version resolved, and `cx build` fetches it if the machine lacks it. A build on a fresh machine cannot silently use the wrong compiler because the tool never falls back to whatever is on `$PATH`.

## Publishing and trust

**A published package is immutable.** Once `1.4.7` exists, no further upload of `1.4.7` succeeds. Yanking hides from new resolutions; it does not overwrite.

**A checksum is over the tarball**, computed by the registry and returned to the client. A client that already had a copy verifies the checksum before using it. A registry that returns a different tarball for a version it has already served is a bug the client detects.

**Signing is deferred, not skipped.** The manifest reserves `signature = "…"` under `[[package]]` in the lock so a signature check can be added without a format change. What is deferred is the PKI: whether it is Sigstore, a web of trust, or a registry-signed attestation is a policy question, and shipping the wrong one is worse than shipping none.

## Diagnostics

The tool's diagnostics obey the same rules as [Diagnostics.md](Diagnostics.md) — a frame does not render half-drawn, spans carry their file. Two new categories:

**Resolution diagnostics** cite the requirement chain that led to the conflict. PubGrub already produces this; the renderer is what turns "no version of `B` works" into

```
error: no version of `bytes` satisfies every requirement.
  ─ mypkg 0.3.1 requires bytes >=0.1, <0.2
  ─ http 1.4.7 (via mypkg) requires bytes >=0.2, <0.3

  http 1.4.7 was chosen because mypkg requires http ^1.4 and 1.4.7 is the newest.
  A version of http that requires bytes ^0.1 would satisfy both; there is none.
```

**Lock drift diagnostics** name what changed and why: `bytes 0.1.4 → 0.1.5 (patch, transitive via http)`.

## What this does not do

**A monorepo build system.** Bazel-style hermetic remote execution, per-file caching, distributed builds are a different tool. `cx` caches per compilation unit and no finer. A team that needs the former can drive `cx build` from Bazel.

**Native code, C libraries, `pkg-config`.** Cronyx does not yet have an FFI. When it does, `[dependencies.native]` or a `link = "…"` field arrives with it; not before.

**A binary distribution channel.** Publishing pre-compiled binaries is a registry feature and a security surface, and it is orthogonal to the package model. Users who want it can put a URL in their manifest today via a `git` source pointing at a tag.

**Language editions.** There is one edition; no `edition` field. When a second arrives, packages declare it in `[package]`, the resolver accepts a mixed graph, and each package compiles under its own edition — but `meta` runs under the package that wrote it, so a macro never sees a foreign edition. Rust's editions are the reference; the commitment is smaller until it needs to grow.

**`cargo install`-style global installs of binaries.** Blocked on a code generator before it is blocked on a registry — there is no binary to install. When both exist they are one feature seen from two sides, since a registry that serves source can serve a compiled binary for a target the tool asks for.

## Open

**Public vs private dependencies.** The rule "one version per public dep, up to two majors per private dep" needs a manifest syntax and a resolver that respects it. `public = true` on a dependency is the obvious spelling; the semantics are what needs pinning down. Rust's RFC 1977 is the reference and the caveats.

**Feature unification across dev-deps.** If `mypkg`'s dev-deps enable a feature of a runtime dep, does the runtime build see it? Cargo's answer changed once (resolver v2) and the change was disruptive. The design here is: no. Dev-deps live in their own resolution scope, sharing the runtime deps' versions but not their feature sets. This needs a fixture before it is a decision.

**What a dependency exports.** Everything it defines. There is no visibility system, and [Modules](Modules.md) resolves namespaces by mangling rather than an export list, so there is nothing yet for a package boundary to narrow. When `pub` arrives it narrows this without changing anything else here.

**Symbol names across packages.** *Todo, and it needs an answer before two packages can be linked.* Modules mangles a unit's declarations to `unit__name`, which two packages that both contain a `util/parse` collide on. The obvious fix is a third segment — `pkg__unit__name` — which makes worse the collision [Modules.md](Modules.md) already documents, where a module `a_b` with `fn c` and a module `a` with `fn b__c` mangle alike. Package names come from a registry rather than from the author, so the reserved-separator-or-reject decision cannot stay informal the way it can inside one package.

**Coherence across a package boundary.** Impls elaborate to plain functions and coherence is global after concatenation, so two dependencies that both write `impl Display for Value` compile fine on their own and collide only in the consumer. No pass owns that check today, and whether overlap is an error or an orphan rule prevents it is undecided.

**How the compiler consumes a dependency** is *not* open, and the toolchain design is why. The lockfile pins an exact compiler version and every package in a build is compiled by that one binary, so a compiled artifact is never read by a compiler other than the one that wrote it. There is no cross-version compatibility requirement, so there is no schema: serialize the compiler's own types, tag the artifact with the compiler version, and key the cache on that tag. A compiler change that alters the types invalidates the cache and everything rebuilds, which leaves `bootstrap`'s types free to change every week. A stable schema is only needed when artifacts cross compiler versions, and the only thing that wants that is a binary cache shared across a team on mixed toolchains — which the pinning deliberately prevents. What remains open is the artifact's *contents*, above, not its format.

**Registry federation.** Two registries defining a package with the same name is a collision waiting to happen. Namespacing by registry (`internal:sekrit`) at the manifest is one answer; a global-name-per-registry policy is another. This is a governance decision as much as a technical one.

**A `cx.workspace.toml` or a `[workspace]` in a leaf manifest.** Both work. The former reads better in a tree with one workspace; the latter matches Cargo's shape. This is small enough to leave for the first user.
