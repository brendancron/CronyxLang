# Attributes

Data written on a field or a variant, read by a deriver, and gone before the program runs.

```cronyx
type Person {
    @rename("full name")
    name: string,

    @skip
    password: string,

    age: int,
}
```

## Why the word is not "annotation"

`Ast.node` is `('a, 'ann)`, and `'ann` is the per-node type slot that carries `unit` through the front end and `Types.ty` after checking. That name was taken first, so the user-facing feature is an *attribute*.

## The reader is `typeof`, not `derive`

A deriver is the common consumer, not the channel. Attributes arrive on `TypeField` and `TypeVariant`, which come from `typeof(T).shape`, so anything that can write that reads them — a deriver, a bare `meta` block, or ordinary code. The third looks like runtime reflection and is not: `Reflect` folds the projection into a literal before CPS, so the loop runs over constants the compiler wrote down and the declaration it came from is already gone.

## Two attachments, two mechanisms

A **member** — a field or a variant — carries its attributes on the member itself, in `Ast.field.f_attrs` and `Ast.variant.v_attrs`.

A **declaration** carries them on a wrapper that only the parse stage has:

```ocaml
type 's attributed = [ `Attributed of attr list * 's ]
```

It is in `stmt_kind` and in no later stage, so `Desugar` unwinding one is what erases it. A field is not a statement, which is why the two cannot be one mechanism.

## Erasure is the whole design

An attribute exists so that generated or reflecting code can read it. Nothing else in the language looks at one: no pass changes behaviour on an attribute, and there is no way to ask for one at runtime.

That is enforced by the shape of the tree rather than by a rule anyone has to remember, and at a different point for each attachment.

A declaration's attributes die at **`Desugar`**: `attributed` is in `stmt_kind` alone, so no later stage has a type that can hold one.

A member's die at **CPS**: `type_defs` appears in `stmt_kind`, `desugared_stmt_kind`, `typed_stmt_kind`, `resolved_stmt_kind` and `reflected_stmt_kind` — and not in `cps_stmt_kind`. A `Type_decl` is therefore already gone by the time `Interp` runs.

Either way a pass that tried to read an attribute after its erasure point would not compile.

`Fn` is why a declaration needs the wrapper rather than a field of its own. It lives in `('e, 's) stmts`, which *every* stage includes, `cps_stmt_kind` among them — so a function survives to the interpreter, and an attribute hung on one directly would survive with it.

This is the same question Java answered with `@Retention` and answered badly: `RUNTIME` retention puts metadata in every artifact, makes reflection the way frameworks work, and defeats static reachability badly enough that ahead-of-time compilers need hand-written configuration to recover it. Go's struct tags make the smaller version of the mistake — a tag is a string nobody validates, so a typo compiles and misbehaves. Rust, D and C++26 keep attributes to compile time, and this follows them.

## Where they live

Attributes are on the AST node, in `Ast.field.f_attrs` and `Ast.variant.v_attrs`, which is what puts them in `Artifact` — an artifact is `Marshal` of `Ast.program`, so a deriver in one package reads attributes written in another with nothing added.

They stay out of `Typecheck.decl`. Unification and `Type_mono` walk that, and neither has a reason to carry inert data. `Typecheck` copies attributes into `ctx_attrs`, keyed by type name and member label, and `Reflect` is the only reader — the same arrangement `ctx_types` already had for a sum's variants, which `Reflect` reads for the same reason.

```
member       parser → typecheck (ctx_attrs) → reflect (TypeField / TypeVariant) → cps drops it
declaration  parser → desugar (decl_attrs, wrapper dropped) → reflect (typeof(T).attrs)
```

Only a **type** declaration is recorded in `decl_attrs`. `typeof(T).attrs` is its one reader and it keys by type name, so a function or a variable recorded under the same key would collide rather than answer. Nothing can ask for those anyway: `typeof` takes a value, and a function value's type — `(int, int) -> int` — names no declaration to look up. Reaching a function's attributes needs a walk over declarations rather than reflection on a value, which is what `Discover.carrying` is and what `@test` uses — see [Testing](Testing.md).

## Arguments are literals

An argument is a `string`, `int`, `float` or `bool` written out, never an expression. There is nothing to evaluate: the parser builds `Ast.attr_arg` directly, and `Reflect` writes it back as an `AttrArg` variant. A deriver matches on it.

```cronyx
for (a in f.attrs) {
    if (str(a.name) == "rename") {
        for (arg in a.args) {
            match arg {
                AttrArg::Str(v) => { label = v; }
                _ => {}
            }
        }
    }
}
```

## Settled

**A declaration carries them too, and `derive` still should not read them.** The earlier rule was that only a member may carry an attribute, on the grounds that whatever a whole type would say is better written as an argument to the deriver — `derive_json(Person, table: "people")`. That reasoning holds for *derivers* and no longer holds as a grammar rule, because a function has to be able to carry an attribute for anything to mark one. So the restriction moved from the parser to taste.

**A named payload's fields do not.** `Circle { r: float }` is a variant's payload, not a member of the type, and reflection reports a variant's arity rather than its fields. Nothing can read an attribute there, so nothing may write one.

## Open

**Nothing rejects an attribute no deriver reads.** `@renmae("x")` compiles and does nothing, which is Go's bug. The fix is Rust's: a deriver declares the attributes it consumes, and an attribute belonging to no declaration is an error. That needs syntax on the deriver — a `uses` clause or similar — and is worth having before attributes are used for anything real.

**A product reports its fields in sorted order, a sum its variants in declaration order.** `Reflect` reads a product's fields off the row, which is sorted, and a sum's variants off `ctx_types`, which is not. That predates attributes, but attributes make it matter: a serializer derived from field order now produces sorted output, which is nobody's intent.
