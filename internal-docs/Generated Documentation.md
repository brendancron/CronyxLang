# Generated documentation

`cx docs`: the declared surface of a package, its dependencies and the standard library, rendered from what the compiler already holds.

The model is `zig docs` — one command that opens browsable reference for the language, its library, and the package you are standing in. This is not a doc *site*: `docs/` is the Docusaurus site written by hand for users, and what this produces is the generated reference that belongs beside it.

One rule shapes everything below: **a reference documents what is declared, not what is reached.**

## The artifact is most of the model

`Artifact.t` already carries the API surface:

```ocaml
type unit_interface = { namespace : string; exports : string list }
type t = { compiler : string; package : string; units : unit_interface list
         ; program : Ast.program; inputs : input list; fingerprint : string }
```

Declarations, mangled under the package's own name, plus the names each unit exports — written by `cx build` for every package in the graph and cached on a fingerprint. So "document this package and everything it depends on" is a walk over linked artifacts, filtered to `exports` and grouped by `namespace`, with no new compilation and no new cache.

That also settles where the tool lives. `cx` is what knows the graph, the roots and the toolchain; the compiler only consumes the decision. Documentation is a mode of `cx`, not a flag on `bootstrap`.

## Why not the checked tree

Metaprocessing is a walk from the roots: a declaration nothing reaches is never metaprocessed and never emitted. Reference built from `Compile`'s output would therefore omit whatever the entry happens not to call, and the omission would be silent and would move with the entry — an exported helper documented on Tuesday and gone on Wednesday because a caller was deleted.

`Precheck` already has the needed semantics: the whole program, reached or not, meta erased, with `Typecheck.partial` treating what a meta block could still declare as unknown. So signatures come from the artifact, and inferred types for an unannotated export come from precheck — never from the post-walk tree. See [Metaprocessing.md](Metaprocessing.md) for the walk and [Architecture.md](Architecture.md) for where the two checks sit.

## Three comments, and `/**` is the only way to write a doc

`//` runs to the newline. `/* … */` nests, so commenting out a region that already holds a comment ends where it was written to end. `/** … */` is a doc comment, and it is `/**` followed by neither `*` nor `/` — which leaves `/**/` an empty comment and `/*** … ***/` a banner, the two shapes someone typing asterisks actually means.

A doc comment *rides* the attribute channel and is *presented* as a doc. `Scanner` emits `Token.Doc`; `Parser.attributes` attaches it to the declaration or member that follows, under `Ast.doc_attr` — a **generated** name, which carries `#` and so cannot be typed. There is no `@doc`, and every surface that meets one shows a comment instead:

- `typeof(T).doc`, `TypeField.doc` and `TypeVariant.doc` are the text, empty where there is none — which is also what an empty doc comment normalizes to, so nothing is lost by not distinguishing them.
- `attrs` never reports one. A deriver matching on attribute names never has to know docs exist.
- `Source` prints `/** … */`, so `--dump-code` shows the comment that was written.

**Why borrow the channel rather than build a second one.** An attribute is already carried from the parser to the artifact and erased before the interpreter, which is exactly a doc's lifetime: `decl_attrs` survives `Desugar`, and the `Attributed` wrapper crosses a package boundary inside the artifact because an artifact is `Marshal` of `Ast.program`. A parallel side table would have been the same table under another name, threaded through the same passes.

Rust makes the underlying attribute writable — `///` is sugar for `#[doc = "…"]` — and that is the part not copied. Two spellings for one thing is a choice every reader has to make and no reader gains from.

**The border asterisks come off in the scanner, and only those.** A `*` down the left margin is punctuation, not text, and a consumer reading the value should not have to know the comment's shape. It is stripped only when *every* line carries one, so a comment whose body is a Markdown list keeps its bullets; the remaining lines are outdented together, so an indented code block keeps its indentation relative to the prose. Nothing else is interpreted — what a fence or a link means belongs to whatever draws the page, and a Markdown dialect in the scanner would be a Markdown dialect in the language definition.

**Printing is the inverse of scanning.** `Source` puts the border back on every line of a multi-line doc, including the blank ones. That is what makes the two operations cancel: a body whose own lines begin with `*` gets a border in front of them and comes back with its bullets, where printing the text bare would have let the next scan mistake a bullet for a border and eat it.

**What reflection cannot reach.** `typeof` takes a value, and a function value's type names no declaration (`Reflect.declared_attrs`). So a doc on a type, a field or a variant is readable from a meta block today, and a doc on a `fn` is recorded and carried but unreadable until declaration reflection lands — the same facility the test framework is waiting on, in [Attributes and Test Frameworks.md](Attributes%20and%20Test%20Frameworks.md).

## What a template documents

A `gen` or a deriver emits declarations that are in no source file, and a template taking a static value exists once per instantiation. Documenting instantiations would mean documenting a set that depends on the program being compiled, which contradicts the rule at the top.

A template is therefore documented as a template — its parameters, its constraints and its own `///` — and its instantiations are not documented at all. What a deriver generates is documented, if at all, by the deriver's own prose. Zig reaches the same place with comptime and for the same reason.

This is the part most likely to feel wrong in use, because metaprogramming is the language's point and the generated surface is real code a caller will meet. `--dump-code` is the answer for now: it prints the program as Cronyx after metaprocessing, which is how to see what a `gen` produced for a particular program.

## The model is the interface

The stable artifact of this work is a **JSON index**, not a page. `cx docs --json` emits it; every renderer reads it.

Three consumers justify the seam. `cx docs` renders and opens it. `docs/` is a Docusaurus site that can take generated API pages into its sidebar beside the hand-written material, which is the payoff that outlives the command. And an editor wanting hover text over a dependency's export needs the same data with no HTML anywhere near it.

## The index

One JSON document per invocation. `cx docs --json` writes it; every renderer reads it and nothing else.

```json
{
  "format": 1,
  "compiler": "0.0.16",
  "root": "geom",
  "packages": [
    {
      "name": "geom",
      "version": "0.1.0",
      "units": [
        { "namespace": "geom", "doc": null, "entries": [ "…" ] }
      ]
    }
  ]
}
```

`version` comes from resolution rather than from the artifact, which does not carry one. `format` is an integer that rises when a reader would break, so a renderer can refuse a document it predates.

### A name is three things

The loader mangles a declaration to `Ast.generated [package; namespace; name]`, joined with `#` — a character the scanner cannot produce, so splitting one back is exact rather than a guess. Every entry therefore carries:

```json
{ "id": "geom#shapes#Point", "package": "geom", "unit": "shapes", "name": "Point" }
```

`id` is unique across the whole graph and is what every cross-reference points at. `name` is what a page is titled with.

*To confirm while building:* `Loader.renamed` leaves the **entry** unit's names unmangled, so a root package documented as an entry rather than as a package would produce bare ids. `cx docs` should go through `Build.package` for exactly that reason, and a fixture should pin it.

### A type reference is structured

A signature printed to a string is a dead end — the renderer cannot turn `List<int>` into a link. So a type is a tree mirroring `Ast.type_expr_kind`, and a name node carries the id it resolved to:

```json
{ "kind": "app", "name": "List", "ref": "std#collections#List",
  "args": [ { "kind": "name", "name": "int", "ref": null } ] }
```

`ref` is null for a builtin, and for a type parameter the node adds `"param": true` so the renderer styles it rather than hunting for a page. The loader already resolves type names before the artifact is written, so the id is in the tree and this costs a projection, not a lookup.

The other nodes are `tuple`, `record`, `fn`, `variadic`, `spread`, `assoc` and `bind`, one per constructor.

**An effect row keeps the difference between empty and absent.** `row: null` is a row left to inference; `row: []` is one written closed. They mean different things to a reader and JSON must not flatten them.

### An entry

Every entry shares a head, and the rest is by kind:

```json
{
  "id": "geom#shapes#Point", "package": "geom", "unit": "shapes", "name": "Point",
  "kind": "type", "exported": true,
  "doc": "A point in the plane.",
  "attrs": [ { "name": "table", "args": [ { "str": "people" } ] } ]
}
```

`doc` is its own field and `attrs` holds what was written with `@`, the same split reflection makes — a consumer of the index never learns that a doc rode in on the attribute channel.

**Everything is in the index, exported or not.** `exported` is membership in the unit's `exports` — the nearest thing Cronyx has to visibility, since there is no export marker and nothing is private. An impl is the one exception: it has no name to export and is reached through its type. The default rendering shows only what is true, so `cx docs --private` costs one boolean now and a re-cut schema later.

| Kind | Carries |
|------|---------|
| `fn` | `static`, `params`, `ret`, `row` |
| `type` | `generics`, `body`, `impls` |
| `trait` | `generics`, `supers`, `assoc`, `methods` |
| `impl` | `trait`, `for`, `generics`, `assoc`, `methods` |
| `effect` | `generics`, `ops` |
| `handler` | `handles`, `arms` |
| `var` | `type` |

A `type`'s `body` is `{"form": "fields", …}` or `{"form": "variants", …}`, and each field and variant carries its own `doc` and `attrs` — which is the whole reason members got them.

A **method** is one shape whether it came from a trait's `method_sig` or an impl's `method_def`: `name`, `doc`, `attrs`, `static`, `params`, `ret`, `row`. The body is not in the index.

### A template is not a generic

`static` and `generics` are separate lists, because `<>` parameters are not generics and the reference must not say they are.

```json
"static": [ { "name": "T", "form": "type", "pack": false },
            { "name": "n", "form": "value", "type": { "kind": "name", "name": "int" } } ]
```

`form` is `value` exactly when the parameter was written with a type — `Ast.static_param.sp_ty` on a function, `Ast.type_param.tp_ty` on a type. That is the bit that makes a declaration a template rather than a generic, so the renderer can label it without inferring anything.

### An impl is its own entry

An impl is a declaration in its own right, it can be written in a different package from the type it is for, and pre-joining its methods onto the type would make the index decide which of several impls owns a name. So impls are entries, and a `type` carries `impls: [ids]` so the renderer joins by id rather than scanning.

An impl has no written name, so its id is built:

```
geom#shapes#Point#impl#std#ops#Index<int>
```

the type's id, `#impl#`, the trait's id, and the trait's written arguments. The arguments are in it because `Index<int>` and `Index<Range>` for one type are two impls of the same trait; overlapping impls are already rejected, so nothing else can collide. An inherent impl ends at `#impl`.

### Ordering

Entries are sorted by `name` within a unit, units by `namespace`, packages by `name`, with the root package first. Sorted rather than in source order because a reference is read by looking a name up, and because a sort is a property of the document rather than of the walk that built it. Nothing in the document holds a path from the building machine.

### Worked

```cronyx
// geom/src/shapes.cx

/** A point in the plane. */
type Point {
    /** How far along. */
    x: int,
    y: int,
}

/** Anything with a written form. */
trait Show {
    /** The written form. */
    fn show(self): string;
}

impl Show for Point {
    fn show(self): string { return str(self.x) + "," + str(self.y); }
}

/** The point both axes pass through. */
fn origin(): Point { return Point { x: 0, y: 0 }; }
```

```json
{
  "format": 1, "compiler": "0.0.16", "root": "geom",
  "packages": [{ "name": "geom", "version": "0.1.0", "units": [{
    "namespace": "shapes", "doc": null,
    "entries": [
      { "id": "geom#shapes#Point", "package": "geom", "unit": "shapes", "name": "Point",
        "kind": "type", "exported": true, "doc": "A point in the plane.", "attrs": [],
        "generics": [],
        "body": { "form": "fields", "fields": [
          { "name": "x", "type": { "kind": "name", "name": "int", "ref": null },
            "doc": "How far along.", "attrs": [] },
          { "name": "y", "type": { "kind": "name", "name": "int", "ref": null },
            "doc": null, "attrs": [] } ] },
        "impls": ["geom#shapes#Point#impl#geom#shapes#Show"] },

      { "id": "geom#shapes#Show", "package": "geom", "unit": "shapes", "name": "Show",
        "kind": "trait", "exported": true,
        "doc": "Anything with a written form.", "attrs": [],
        "generics": [], "supers": [], "assoc": [],
        "methods": [
          { "name": "show", "doc": "The written form.", "attrs": [], "static": [],
            "params": [{ "name": "self", "type": null }],
            "ret": { "kind": "name", "name": "string", "ref": null }, "row": null } ] },

      { "id": "geom#shapes#Point#impl#geom#shapes#Show",
        "package": "geom", "unit": "shapes", "name": "Show for Point",
        "kind": "impl", "exported": true, "doc": null, "attrs": [],
        "trait": { "ref": "geom#shapes#Show", "name": "Show", "args": [] },
        "for": { "kind": "name", "name": "Point", "ref": "geom#shapes#Point" },
        "generics": [], "assoc": [],
        "methods": [
          { "name": "show", "doc": null, "attrs": [], "static": [],
            "params": [{ "name": "self", "type": null }],
            "ret": { "kind": "name", "name": "string", "ref": null }, "row": null } ] },

      { "id": "geom#shapes#origin", "package": "geom", "unit": "shapes", "name": "origin",
        "kind": "fn", "exported": true,
        "doc": "The point both axes pass through.", "attrs": [],
        "static": [], "params": [],
        "ret": { "kind": "name", "name": "Point", "ref": "geom#shapes#Point" },
        "row": null }
    ] }] }]
}
```

Four things to read off it. `self` has no written type, so its `type` is null rather than invented — the index reports what was written, and inferring here would be the checker's job done twice and done worse. The trait's method carries the doc and the impl's does not, which is the common case and the renderer's cue to fall back to the trait's prose. `origin`'s return links to `Point` while `int` and `string` do not, because a builtin has no declaration to link to. And the impl sorts under `Show for Point`, the name it is written and titled with, which puts it after the trait rather than beside the type — `Point.impls` is what keeps the two connected, not their position in the list.

## Rendering is static

Zig serves its reference from a WASM binary that walks serialized compiler data, which buys incremental search over a very large standard library. Cronyx's is small and the index is cheap to emit, so `cx docs` writes static HTML into `target/doc/` and opens it. No server in the first version, no WASM, no JavaScript that has to agree with the compiler about anything.

`target/doc/` and not a checked-in directory: generated output is a build product, and `cx new` already puts `target/` in `.gitignore`. The library has no `target/` of its own, so `cx docs std` writes to `~/.cronyx/doc/std` — it belongs to the toolchain rather than to whichever project you happened to be standing in.

## The standard library is not a package

`import "std/…"` resolves through the toolchain rather than the filesystem, and `stdlib` is not compiled to an artifact ([Package Manager Plan.md](Package%20Manager%20Plan.md), milestone 3). `Toolchain.up_from` and `Toolchain.beside_binary` locate the directory, so `cx docs std` is the same walk over a different loader root, reading source rather than an artifact until `std` is compiled like any other package.

That also means `cx docs` must work outside a package. Standing nowhere in particular and asking for the library is the common case — it is most of what `zig std` is for — so the command cannot begin by demanding a `cronyx.toml`.

## Build order

A milestone is done when its criteria hold *and* a fixture covers each one: `tests/` for anything the compiler does, `cx/test/packages/` for anything about a graph.

### 1. The compiler keeps doc comments — built

`/* … */` and `/** … */` in the scanner, the latter becoming a `doc` attribute in the parser.

- A doc comment on a type, a field or a variant is readable from a meta block as `.doc`, it is absent from `.attrs`, and `//` is still discarded. *(`tests/meta/attributes/doc_comments`.)*
- A doc comment in a position that documents nothing is a diagnostic. *(`tests/meta/attributes/errors/doc_not_a_declaration`.)*
- Block comments nest, and `/**/` and `/*** … ***/` are ordinary comments. *(`tests/core/syntax/block_comment`; the unterminated case is `tests/core/syntax/errors/unterminated_block_comment`.)*

**Still open here.** That a doc on a dependency's export survives the artifact follows from attributes surviving it, and no fixture yet says so — `cx/test/packages` is where that one belongs.

### 2. Methods carry attributes — built

A trait's method signatures and an impl's methods took neither an attribute nor a doc comment, which left the largest part of a trait's and a type's surface undocumentable. Both now read `Parser.attributes` before `fn`, and a method carries them on the member — `ms_attrs`, `md_attrs` — as a field and a variant already do, because a method is not a statement either.

Erasure needs no new rule. `Resolve` turns every impl into plain functions, and `cps_stmt_kind` holds neither `type_defs` nor `method_defs`, so no later stage has a type that could carry one.

- A doc comment and an attribute on a trait method and on an impl method compile, and the program is unchanged. *(`tests/core/syntax/doc_comment`.)*
- They survive metaprocessing into the surface tree an artifact is made of, which `--dump-code` prints.

**Still open here.** `typeof(T).shape` reports fields and variants and says nothing about methods, so a meta block cannot read a method's doc even though `cx docs` can. Closing that is the same declaration-reflection work a `fn`'s doc waits on.

### 3. `cx docs --json` — built

`cx/lib/json.ml` is a writer and no reader; `cx/lib/docs.ml` walks the artifacts `Build.package` returns and emits the index above. No compiler change was needed.

- Every declaration of every unit of every package, sorted, with a doc comment, a signature and attributes. *(`cx/test/packages/documented/app`, whose `expected.json` is compared cold and again over the artifacts the first build left.)*
- A type reference carries the id it resolved to, across a package boundary: `origin(): shapes.Point` indexes as `"ref": "shapes#Point"`.
- The document holds no path from the building machine, and the compiler's version is the only thing that moves — the fixture names it rather than pinning it.

**A unit that documents nothing is left out.** Every package embeds whatever of the standard library it imported, and `Artifact.units` lists those beside its own. Their declarations carry the library's names rather than the package's, so they are skipped here and belong to `cx docs std`.

Building it turned up one thing the index could not express, which is the next section.

### 3a. An effect is a declaration; an operation is a member — built

`Loader` renamed a `fn`, a `type` and a `trait` to `package#unit#name` and left `Effect_decl` and `Handler_decl` alone, so both kept the name they were written with and every effect in a linked program shared one namespace. An effect's index id was `Missing` rather than `app#ink#Missing`, which a renderer keying pages by id would have collided.

Both are now renamed like anything else, and both are in `declared_name` and so in `exports`. An **operation** is not: it is a member of its effect, reached through it, and `Typecheck` already refuses two effects that declare one operation name — so a member name is unique across a linked program without being mangled to say so.

What follows from that:

- `handle`, `with` and `handler x : E` take a qualified name, through the same `Parser.qualified_name` that `derive` already used.
- A written effect row names declarations, so `Loader` resolves one.
- `sig.boop` resolves to the operation rather than to a mangled name. The alias needs the target's operation names to know that, so `Artifact.unit_interface` carries `operations` — an artifact a consumer reads is one the same compiler wrote, so the field costs a rebuild and nothing else.
- A consumer reaches an effect the way it reaches a type: `import "sig" { Beep }`, or `sig.Beep`. `import "std/lang/Error"; handle Error` no longer resolves, and the two stdlib fixtures that relied on it now import the effect by name.

*(`tests/effects/named_import` imports an effect selectively; `tests/effects/qualified_op` calls an operation through its module from a non-entry unit. `tests/effects/errors/across_modules` is the same program with the imports the other way round, which still fails — an operation's visibility depends on import order, which that pair now documents from both sides.)*

### 4. A renderer — built

`cx/lib/site.ml` writes static HTML from the index, reading nothing else. One page per unit with each declaration anchored inside it, so a cross-reference is a path and a fragment and needs no server and no script. An id carries `#`, which would have to be percent-encoded in a fragment, so an anchor is the id with dots.

The doc comment gets paragraphs, bullets, fenced blocks and inline code — not a Markdown implementation. Guessing at emphasis would turn `a * b` italic, and a doc that wants more than this is saying the renderer needs a real parser.

- A package with no doc comments documents from signatures. *(`cx/test/packages/geom`, a bare `type Point { x: int, y: int }`.)*
- Every cross-reference resolves, including into a dependency. Checked by crawling the pages rather than by diffing HTML: every `href` must reach a file that exists and an anchor that is in it, and every entry the index holds must have a page. A diff would check neither and would break on any change of style. *(`run_render_case`, verified to fail by breaking each of the two link forms in turn.)*

### 5. The command — built

`cx docs` renders and opens. `--json` writes the index instead, `--no-open` renders without a browser.

`cx docs std` documents the toolchain's library. That needed a loader entry point that did not exist: `Loader.package` takes an entry file and a library has none, so the part of it after the units are loaded is now `Loader.assemble`, which takes the entry as an option. `Loader.library` passes `None` — every module is a module, nothing keeps plain names, and no top-level statement is kept.

- `cx docs std` works in a directory with no `cronyx.toml`, writing to `~/.cronyx/doc/std` rather than to a `target/` that a library does not have. *(`run_library_case`, with `CRONYX_STDLIB` pointed at a fixture library and the real one put back afterwards.)*
- `cx docs` reuses `cx build`'s cache, because it is `Build.package` that produces the artifacts it walks.

**What it found, and what now stops it happening again.** `cx docs std` compiles every module of the library rather than the ones something imports, which is the rule the whole reference is built on. Two files under `stdlib/lex/` did not parse: they were written against an older Cronyx that had `enum` and dotted imports, nothing referenced either, and neither this suite nor `cx-parity.sh` had ever looked at them, both walking only `tests/`. Both are deleted.

`run_stdlib_parses` now scans and parses every file the library ships, named by a fixture or not. Parsing is the right depth: `stdlib/ops/` legitimately fails to *check* standalone, because those modules name builtins that exist only in a linked program, and a reference reads surface syntax rather than types.

## Open

**Whether a line doc comment is worth having.** `/** … */` is the only doc form. A block comment is a poor fit for a one-line doc on twenty consecutive fields, and it reflows when a line is added, which diffs badly. `///` is currently an ordinary line comment, so adding it later costs nothing and breaks nothing.

**Whether the index is keyed for search.** A reference is searched more than it is browsed, and a flat list of entries makes the renderer build its own search structure. Deferred rather than decided: what a search index should hold depends on what the renderer's search does, and nothing has one yet.

**Where prose about a *unit* goes.** A module-level doc has no declaration to hang on. A `/** … */` at the top of a file with nothing after it is the usual answer, and it is a deliberate carve-out rather than an accident: that shape is exactly what milestone 1 made a diagnostic.

## Settled

**Documentation does not run.** No doctest, and no example extracted from a doc comment and compiled. `cx test` runs `@test` functions ([Testing.md](Testing.md)); an example that must stay true belongs there, and making prose executable buys a second test runner with worse diagnostics.

**Where a doc comment may be written.** Wherever an attribute may be: a `fn`, `type`, `trait`, `impl`, `effect`, `handler` or `var`, a field, a variant, and a method of either a trait or an impl. A parameter is not a declaration and carries none — describing parameters in the prose, as Rust does, is cheaper than inventing a fifth attachment point for a name a signature already gives.

**The compiler does not render.** `bootstrap` records doc text and emits it in the artifact. Markdown, HTML and the browser are `cx`'s, which keeps the language definition free of a document format.
