# Generated documentation

`cx docs`: the declared surface of a package, its dependencies and the standard library, rendered from what the compiler already holds.

The model is `zig docs` — one command that opens browsable reference for the language, its library, and the package you are standing in. This is not a doc *site*: `docs/` is the Docusaurus site written by hand for users, and what this produces is the generated reference that belongs beside it.

One rule shapes everything below: **a reference documents what is declared, not what is reached.**

## The artifact is most of the model

`Artifact.t` already carries the API surface:

```ocaml
type unit_interface = { namespace : string; path : string option
                      ; doc : string option; exports : string list
                      ; operations : string list }
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

## What a comptime function documents

A `gen` or a deriver emits declarations that are in no source file, and a comptime function exists once per instance. Documenting instances would mean documenting a set that depends on the program being compiled, which contradicts the rule at the top.

A comptime function is therefore documented as one — its parameters, its constraints and its own `///` — and its instances are not documented at all. What a deriver generates is documented, if at all, by the deriver's own prose. Zig reaches the same place with comptime and for the same reason.

This is the part most likely to feel wrong in use, because metaprogramming is the language's point and the generated surface is real code a caller will meet. `--dump-code` is the answer for now: it prints the program as Cronyx after metaprocessing, which is how to see what a `gen` produced for a particular program.

## The model is the interface

The stable artifact of this work is a **JSON index**, not a page. `cx docs --json` emits it; every renderer reads it.

Three consumers justify the seam. `cx docs` renders and opens it. `docs/` is a Docusaurus site that can take generated API pages into its sidebar beside the hand-written material, which is the payoff that outlives the command. And an editor wanting hover text over a dependency's export needs the same data with no HTML anywhere near it.

## The index

One JSON document per invocation. `cx docs --json` writes it; every renderer reads it and nothing else.

```json
{
  "format": 3,
  "compiler": "0.0.17",
  "root": "geom",
  "packages": [
    {
      "name": "geom",
      "version": "0.1.0",
      "units": [
        { "namespace": "shapes", "path": "src/shapes.cx",
          "doc": "Shapes, and what they are made of.", "entries": [ "…" ] }
      ]
    }
  ]
}
```

**A unit is a file, not a name.** `path` is where it was written, relative to the root of the package that owns it, and units are ordered and grouped by it. Two units may share a namespace — `Loader.namespace_of` calls both `a/Util.cx` and `b/Util.cx` `Util` — so a document keyed by namespace would merge their declarations and report the module twice. The path is also what a renderer groups a tree by, and what a source link is resolved against; it is relative because nothing in the document may hold a path from the building machine.

A unit the artifact *embeds* rather than owns has `path: null` — a dependency's layout is its own package's business — and that is also the filter that keeps another package's declarations out of this one's reference.

`doc` is the unit's own prose: the doc comment at the top of its file.

`version` comes from resolution rather than from the artifact, which does not carry one. `format` is an integer that rises when a reader would break, so a renderer can refuse a document it predates. It is **3**. Two moved it: a unit gained `path`, an entry gained `line`, a `<>` parameter's `form` gained `bound`, a trait gained `impls`, and the object in an effect row calls its label `name` rather than `effect` like every other reference in the document. Three made a trait's `assoc` a list of objects rather than of names, so that an associated type can carry its own `doc` and `attrs` as an operation now does.

### A name is three things

The loader mangles a declaration to `Ast.generated [package; namespace; name]`, joined with `#` — a character the scanner cannot produce, so splitting one back is exact rather than a guess. Every entry therefore carries:

```json
{ "id": "geom#shapes#Point", "package": "geom", "unit": "shapes", "name": "Point" }
```

`id` is unique across the whole graph and is what every cross-reference points at. `name` is what a page is titled with.

**Where a declaration lives is the span's question, not the name's.** The mangled name says what to call a declaration and nothing about where it was written: an `impl` carries the name of the type it is *for*, so `impl Add for int` mangles under `int` and splitting it places the impl nowhere — which silently dropped every impl for a primitive from the whole document, and with it the only way to find out that `int` adds. A declaration is therefore placed by matching its span's path against the units' paths, longest suffix first, and the mangled name is used only to recover the `name`. A name that does not split — an impl's, or an entry unit's, which `Loader.renamed` leaves plain — is the name as written.

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

Every entry also carries `line`, the line its declaration begins on, or `null` for one the compiler invented. With the unit's `path` that is a source link, and it is split that way rather than repeated per entry because a unit is one file.

| Kind | Carries |
|------|---------|
| `fn` | `static`, `params`, `ret`, `row` |
| `type` | `generics`, `body`, `impls` |
| `trait` | `generics`, `supers`, `assoc`, `methods`, `impls` |
| `impl` | `trait`, `for`, `generics`, `assoc`, `methods` |
| `effect` | `generics`, `ops` |
| `handler` | `handles`, `arms` |
| `var` | `type` |
| `builtin` | as `fn`, for a native with no declaration behind it |

A `type`'s `body` is `{"form": "fields", …}` or `{"form": "variants", …}`, and each field and variant carries its own `doc` and `attrs` — which is the whole reason members got them.

A **method** is one shape whether it came from a trait's `method_sig` or an impl's `method_def`: `name`, `doc`, `attrs`, `static`, `params`, `ret`, `row`. The body is not in the index.

### A comptime function is not a generic

`static` and `generics` are separate lists, because `<>` parameters are not generics and the reference must not say they are.

```json
"static": [ { "name": "T", "form": "type", "pack": false },
            { "name": "K", "form": "bound", "type": { "kind": "name", "name": "Hash", "ref": "std#ops#Hash#Hash" } },
            { "name": "n", "form": "value", "type": { "kind": "name", "name": "int" } } ]
```

`form` is one of three, and the *written* type does not say which: `<T: Hash>` is a generic the checker constrains and `<n: int>` is a value a copy is made for, and both are a name with a type expression after it. What separates them is whether the head of that type names a trait — the same question `Metaprocess.is_value` asks of the trait table, and the reason the index carries the kind of every declaration and not only its display name. Calling a bound a value, which is what one boolean got you, told a reader that `find<K: Hash, V>` was comptime.

### An impl is its own entry

An impl is a declaration in its own right, it can be written in a different package from the type it is for, and pre-joining its methods onto the type would make the index decide which of several impls owns a name. So impls are entries, and a `type` carries `impls: [ids]` so the renderer joins by id rather than scanning.

**A trait carries the same list.** Not a convenience: `impl Add for int` has no type page to be listed on, because `int` is a builtin and has no declaration, so the trait is the only place an impl for a primitive can be found. Every operator trait's implementers are in that list and nowhere else.

An impl has no written name, so its id is built:

```
geom#shapes#Point#impl#std#ops#Index<int>
```

the type's id, `#impl#`, the trait's id, and the trait's written arguments. The arguments are in it because `Index<int>` and `Index<Range>` for one type are two impls of the same trait; overlapping impls are already rejected, so nothing else can collide. An inherent impl ends at `#impl`.

### Ordering

Entries are sorted by `name` within a unit, units by `path`, packages by `name`, with the root package first. Sorted rather than in source order because a reference is read by looking a name up, and because a sort is a property of the document rather than of the walk that built it. Nothing in the document holds a path from the building machine.

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

## A module's prose is the top of its file

A doc comment needs a declaration to attach to, and a module has none — which left the reference able to say what every declaration was and nothing about what a module was *for*, the half of a reference a reader starts from.

A `/** … */` at the top of a file, with a blank line under it, is therefore the unit's doc. A blank line, because the alternative is a fourth comment form: Rust and Zig both spell a module doc differently from a declaration doc (`//!` against `///`) precisely because position alone is ambiguous at exactly this spot, and a separating line is the smaller change. `Scanner` is where the whitespace still exists to be read — by the time the parser holds the token it is gone — so `Token.Doc` carries the text *and* whether a blank line follows, and `Parser.parse_unit` takes such a token as the unit's doc when it is the first thing in the file. Everywhere else a blank line means nothing and the comment attaches to the declaration below it, so the only cost of writing one is the line between them.

It retracts part of a diagnostic: `doc_not_a_declaration` exists to reject a doc comment attached to nothing, and this makes one position legal. The fixture stays for every other position, and `tests/core/syntax/module_doc` and `tests/meta/attributes/module_doc` cover the legal one from both sides — the second by asking `typeof(T).doc` and getting nothing, which is what says the prose did not land on the type.

**Printing cannot misplace it**, which was the worry. A module doc never becomes an attribute and never enters the AST, so `Source.program` has nothing to print and nothing to put in the wrong place; what it costs is that `--dump-code` does not show it, the same way it shows no other thing that is not a declaration.

## The natives are documented from a table

`print`, `str`, `panic`, `ord` and the methods on the primitives are OCaml in `builtins.ml`: a thunk producing their type, and an implementation. There is no AST node, so there is nothing to carry a doc comment — and they are the most-used names in the language, so a reference without them has a hole in the middle of it.

Each entry carries its prose beside its thunk, and `Docs` emits it as an entry of kind `builtin` in a synthetic unit of the `std` package. The printed signature is built *from the thunk's types* rather than from a second written form, so only the prose is written once rather than the signature twice. Ids are synthesised — `builtin#print`, `builtin#string#bytes` — because nothing mangles a name that is never declared, and without one no signature could link to it.

An empty doc is what says a name is the compiler's own business, which is how `__parse_int`, `__structural_eq` and the generated `meta#…` names stay out.

Rejected: a body-less `@native fn` in `stdlib/core`. It would put the signature and its prose in Cronyx and delete the thunks, but it needs an attribute, an exemption from mangling — `Typecheck.declare_builtins` binds a native under its bare name, so a declaration inside a module would be looked up as `std#core#print` and not found — and a checker path that reads a written signature where it reads a thunk today.

## Rendering is static

Zig serves its reference from a WASM binary that walks serialized compiler data, which buys incremental search over a very large standard library. Cronyx's is small and the index is cheap to emit, so `cx docs` writes static HTML into `target/doc/` and opens it. No server in the first version, no WASM, no JavaScript that has to agree with the compiler about anything.

`target/doc/` and not a checked-in directory: generated output is a build product, and `cx new` already puts `target/` in `.gitignore`. The library has no `target/` of its own, so `cx docs std` writes to `~/.cronyx/doc/std` — it belongs to the toolchain rather than to whichever project you happened to be standing in.

**A page is a unit's path**, not its namespace: `std/collections/HashMap.html` beside `std/core/Array.html`, which is what keeps two units of one name from being one page. A cross-reference is therefore a relative path of the right depth and a fragment, and the index page groups the units by the directories they sit in. A package's modules are all under `src/`, which is the one segment a consumer never writes, so it comes off the page path and off the import line.

**There is one script, and it does not fetch.** The pages carry a search box over the same index they were rendered from — a reference is searched more than it is browsed, and thirty-odd modules is the last moment at which that is not true. It cannot be `fetch('index.json')`: a `file://` page asking for a sibling file is a cross-origin request and every browser refuses it, so the search would be dead in exactly the case `cx docs` opens. A `<script>` is under no such rule, so the rows are also written as `search-index.js`, an assignment to a global. `index.json` is written beside the pages all the same, for the consumers that are not a browser reading a local file — which is the seam [The model is the interface](#the-model-is-the-interface) is about.

## The standard library is not a package

`import "std/…"` resolves through the toolchain rather than the filesystem, and `stdlib` is not compiled to an artifact ([Package Manager Plan.md](Package%20Manager%20Plan.md), milestone 3). `Toolchain.up_from` and `Toolchain.beside_binary` locate the directory, so `cx docs std` is the same walk over a different loader root, reading source rather than an artifact until `std` is compiled like any other package.

That also means `cx docs` must work outside a package. Standing nowhere in particular and asking for the library is the common case — it is most of what `zig std` is for — so the command cannot begin by demanding a `cronyx.toml`.

### `core` is loaded like any other module

The declarations every program has before it imports anything — `Option`, `Ordering`, `Range`, `impl Array<T>`, `impl string`, the operator traits, `Assertion` and `assert`, and beside them `collections/List`, `Map` and `Set`, `meta/Reflect` and `text/String` — are ordinary files under `stdlib/`, loaded and mangled under their own paths like every other module. `cx docs std` walks them with the rest.

Two things reach them. The compiler names about twenty itself — the operator traits, `Option` and `Ordering` for what `partial_cmp` answers, `Range` for what `a[1:]` becomes, the reflection types, the `__is_*` tests behind `< <= > >=`, and `Assertion`, whose handler `cx test` synthesises — and reaches each by the name the loader gives it, listed in `Core`. `Core.modules` is what `Loader` loads with every program for that reason, whether or not anything imports them, which also puts the methods of a primitive in every program: `"a,b".split(',')` is reached through the value rather than a name. What a *file* sees without an import is only the `global import`s in `stdlib/prelude.cx`, so a program's own `Option` is a different name rather than a replacement, and the library's stays reachable as `core.Option`.

**What it cost.** `Toolchain.stdlib ()` must succeed for every compile rather than only for an `import "std/…"`, and a declaration the compiler names became a mismatch found when the compiler looks for it rather than one the language cannot express.

**What it found.** `Metaprocess` registered a trait in its trait table by matching `Trait_decl` directly, so a trait wrapped in `Attributed` — which is what a doc comment makes — was invisible to it. Every bound naming such a trait was then read as a static *value* parameter and the walk demanded arguments nobody had written. Nothing showed it while the prelude carried no doc comments; documenting the operator traits broke four fixtures at once. `tests/core/traits/documented_bound` is the case.

`stdlib/ops/` also held an `Add`, `Sub`, `Mul`, `Div`, `Mod`, `Eq`, `Ord`, `Inc`, `Dec` and the `*Assign` traits — declared against the wrong arity (`trait Add { fn add(self, other); }` beside core's `trait Add<Rhs> { type Output; … }`), imported by nothing, and what the reference showed in place of the real operator traits. They are deleted. `Hash`, `To` and `TryTo` are imported and stay.

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
- A consumer reaches an effect the way it reaches a type: `import "sig" { Beep }`, or `sig.Beep`. `import "std/core/Error"; handle Throw` does not resolve; `import { Throw } from "std/core/Error"` does.

*(`tests/effects/named_import` imports an effect selectively; `tests/effects/qualified_op` calls an operation through its module from a non-entry unit. `tests/effects/errors/across_modules` performs an operation bare after a plain `import`, which the loader rejects with the two forms that would reach it.)*

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

### 6. What an audit of the rendered library found — built

The reference existed and was thin: no generics on a trait, an impl or an effect, no associated types, no supertrait arguments, no implementers, an effect row that printed as `<>`, every impl for a primitive missing outright, one flat alphabet of thirty-four modules, and almost no prose because the library had none to show.

- The renderer prints every `<>` parameter list the index carries, the associated types on both sides of a trait, a supertrait's arguments, and the row where it is written — `-> <E> bool`, as `Source` prints it. *(`cx/test/library`, whose `Ops.cx` carries a parameterised trait, a supertrait at arguments, two impls for primitives, a bound naming a trait at arguments, a comptime function, a parameterised effect and a handler.)*
- A page groups its entries by kind and names the import that reaches the unit; an impl's title carries the trait's arguments, so `Index<int>` and `Index<Range>` are two entries rather than one heading twice.
- Every impl is reachable: through its type where there is one, and through its trait where there is not. The library's own pages are crawled for this, not only a package's — a primitive's impls appear nowhere else. *(`run_library_case`, which now renders and crawls.)*
- The library has prose: a module doc on every module, and doc comments over the core surface, the collections, the string functions, the effects and the conversions.

## Open

**Whether a line doc comment is worth having.** `/** … */` is the only doc form. A block comment is a poor fit for a one-line doc on twenty consecutive fields, and it reflows when a line is added, which diffs badly. `///` is currently an ordinary line comment, so adding it later costs nothing and breaks nothing.

**Nothing documents what a `gen` produced.** Unchanged, and still the part most likely to feel wrong in use — see [What a comptime function documents](#what-a-comptime-function-documents).

## Settled

**Documentation does not run.** No doctest, and no example extracted from a doc comment and compiled. `cx test` runs `@test` functions ([Testing.md](Testing.md)); an example that must stay true belongs there, and making prose executable buys a second test runner with worse diagnostics.

**Search is a script over the index.** What it holds is a name, a kind, the unit it is in and its anchor — a name is what a reference is searched by, and the whole of every doc comment would be the pages again in one file. See [Rendering is static](#rendering-is-static) for why it is a `<script>` and not a `fetch`.

**Where prose about a *unit* goes.** The leading doc comment of its file, separated by a blank line — see [A module's prose is the top of its file](#a-modules-prose-is-the-top-of-its-file).

**Where a doc comment may be written.** Wherever an attribute may be, with no exceptions: a `fn`, `type`, `trait`, `impl`, `effect`, `handler` or `var`, a field, a variant, a method of either a trait or an impl, an effect's **operation**, and an **associated type** on either side — `type Item;` in a trait and `type Item = int;` in the impl that binds it.

The last two came late, and what made them awkward was not the parser. An operation and an associated type were the two members carrying nothing but their own name: `Ast.op_decl` had no attribute field, `trait_body.tb_assoc` was a `string list` and `impl_body.ib_assoc` was an association list the checker read with `List.assoc`. Both are records now — `assoc_decl` and `assoc_def` — with `Ast.assoc_names`, `assoc_bound` and `assoc_binds` for what the checker was doing by hand, which is why the change reaches `Typecheck` in eight places and means nothing at any of them. The parser reads `attributes` *before* it dispatches on `type` against `fn`, since a doc comment and an `@` both come before either word.

A parameter still carries none: it is not a declaration, and describing parameters in the prose, as Rust does, is cheaper than inventing an attachment point for a name a signature already gives. A parameter is not a declaration and carries none — describing parameters in the prose, as Rust does, is cheaper than inventing a fifth attachment point for a name a signature already gives.

**The compiler does not render.** `bootstrap` records doc text and emits it in the artifact. Markdown, HTML and the browser are `cx`'s, which keeps the language definition free of a document format.
