Status: **implemented.** `lib/types.ml` and `lib/typecheck.ml` run after `Desugar`; every program goes through the checker. See [Architecture](Architecture.md) for where that sits now.

This records the design of the OCaml bootstrap's static type system, what was carried over from the Rust bootstrap's checker (`legacy-bootstrap/src/semantics/types/`), what was done differently, and what is still missing.

## Context

Before this, `bootstrap` was a tree-walking interpreter over a dynamically typed language and no stage consulted a type.

Types are needed downstream, not merely for error reporting. That decides several things below — most importantly that the checker must *produce* an annotated tree rather than just validate and discard. Known consumers:

- **codegen** — LLVM needs `i64` vs `double` vs pointer.
- **operator overloading** — static types are what let `` `Binop `` lower to a direct call instead of a runtime dispatch table. See "Related work" below.
- **monomorphization or method dispatch**, if the language grows them.

## Decisions

| Question | Decision |
|----------|----------|
| Numerics | Split `int` / `float`. No implicit widening. |
| Annotations | Optional everywhere; full inference. |
| Operator constraints | A bound on the operator's own trait, not a built-in kind. |
| Polymorphism | Full let-polymorphism, with the value restriction. |
| First cut | Typed AST end-to-end, interpreter runs on it. |
| Desugar spans | Fixed before the checker is written. |
| Effects | Every function type carries a row. See [Algebraic Effects](Algebraic%20Effects.md). |

## Representation: two type languages, not one

```ocaml
(* Inference time: mutable and incomplete. *)
type infer_ty =
  | IInt | IFloat | IStr | IBool | IUnit
  | IFn of infer_ty list * infer_ty * infer_row
  | IVar of tv ref
and tv = Unbound of int * kind | Link of infer_ty
and kind = Any | Collection of infer_ty | Bound of bound list | Projection of infer_ty * string

(* After inference: fully resolved. No unification variable can appear. *)
type ty =
  | Int | Float | Str | Bool | Unit
  | Fn of ty list * ty * row
  | Generic of int
```

The row on a function type is its effects; see [Algebraic Effects](Algebraic%20Effects.md).

`resolve : infer_ty -> ty` collapses `Link` chains, defaults unconstrained numeric variables to `Int`, and maps anything still genuinely unconstrained to `Generic`.

The point of two representations is that an *unresolved* type variable is unrepresentable downstream: nothing consuming `ty` has to ask "what if this is still being inferred". This is the same discipline that keeps `` `Compound `` and `` `For `` out of the interpreter via `desugared_stmt`, and it is the structural fix relative to the Rust bootstrap, where unresolved variables leak into the type map and later stages compensate.

`Generic` is the concession full let-polymorphism forces. `fn id(x) { return x; }` is `'a -> 'a` and its body genuinely has no concrete type, so `ty` needs a way to say "quantified" as distinct from "not yet known". A `Generic` reaching codegen means that call site was never monomorphized — a marker for work to do, not an unresolved variable.

The surface spelling is Cronyx's: `int`, `float`, `string`, `char`, `byte`, `bool`, `unit`. The OCaml constructors are `Str`, `Chr` and `Byte`, but no user ever writes those.

Cost: one conversion function and some duplication between the two types.

## Annotation: parameterize `node`, don't build a parallel AST

```ocaml
type ('a, 'ann) node = { it : 'a; span : span; ann : 'ann }

type desugared_expr = (desugared_expr_kind, unit) node
and  desugared_expr_kind =
  [ lit | desugared_expr vars | desugared_expr ops | desugared_expr logic ]

type typed_expr = (typed_expr_kind, ty) node
and  typed_expr_kind =
  [ lit | typed_expr vars | typed_expr ops | typed_expr logic ]
```

The fragments in `ast.ml` are already parameterized over their child type, so the typed AST costs about six lines instead of a re-declaration of every constructor — the same payoff that made `desugared_expr` cheap. `at` gains `ann = ()`; untyped stages are otherwise unchanged.

A side table keyed by node id (what the Rust bootstrap uses) is the wrong choice here specifically because `bootstrap` has no node ids. Adopting one would mean inventing an `IdProvider` solely to serve the type checker.

Annotate expressions. Statements are all `Unit` except `` `Return ``, which is checked against the enclosing signature — so inference threads a "current return type" downward, the way the evaluator threads `Return_value`.

## Pass structure

```
desugared_stmt list
  → hoist      bind every top-level fn signature
  → infer      walk, unify, annotate with infer_ty   (mutates tv refs)
  → resolve    infer_ty → ty everywhere; error on unbound
  → typed_stmt list
```

Two traversals after the hoist, because Hindley–Milner cannot finish a node's type when it first visits it: in `fn f(x) { return x + 1; }`, `x` is only pinned at the `+`. Fusing infer and resolve means threading a substitution by hand; the separate resolve pass is far easier to get right.

The hoist pass also produces the function signature table (`(string, ty) Hashtbl.t`) that codegen wants for emitting declarations before any body is compiled.

## Operator constraints

Two numeric types plus annotation-free inference makes `fn double(x) { return x + x; }` ambiguous — nothing pins `x` to `int` or `float`. It resolves through the same traits a written bound would name, so there is no separate mechanism for operators:

- A fresh variable is `Unbound (id, Any)`.
- An operator unifies its operands with each other and bounds the result by the operator's own trait — `Add`, `PartialOrd`, `Neg`. Since the operands were just unified, the bound also says `Output = T`.
- Unifying that variable with a type having no such impl fails with "Expected Add, got Foo", which names what to write.
- Unifying two variables takes the stronger constraint; a projection wins over any of them, being the only kind that says where a type comes from.
- At `resolve` time a still-unbound variable becomes `Generic`, since it is polymorphic rather than ambiguous.
- A variable introduced by a **written** type parameter — `fn f<T>`, `impl Box<T>` — is registered in `Types.declared_params`, which keeps it the survivor when two variables merge so a recursive occurrence still quantifies over the identity the author gave it.

Forgetting that registration is invisible for a long time. The binding still generalizes, so the definition type checks and so does every call; only the *body's* annotations are wrong, and they are wrong in a way that looks right at the first instantiation. `impl` parameters were created with a bare `fresh ()` for exactly this reason, and the symptom was a `Pair<Vec2>` whose method had been resolved at `int` — passing the checker and failing in the interpreter.

There is no implicit widening: `1 + 2.5` is a type error, and mixing requires an explicit conversion. Subtyping interacts badly with unification, and the error messages it produces are markedly worse.

## Polymorphism and the value restriction

Generalization happens at both `fn` and `var`, so `fn id(x) { return x; }` is `'a -> 'a` and usable at several types.

Because `var` bindings are reassignable, naive generalization is unsound:

```cronyx
var f = fn(x) { return x + 1; };   // generalized to 'a -> 'a ?
f = fn(x) { return x; };           // each use instantiates fresh
f("hi");                           // passes the checker, misbehaves at runtime
```

A `var` is therefore generalized only when **both** hold:

1. its initializer is a syntactic value (literal, function literal, variable) — the standard value restriction, and
2. the binding is never reassigned in its scope — a cheap pre-scan over assignments.

Everything else stays monomorphic.

Consequence to plan for: inferred polymorphism means LLVM codegen will need **monomorphization**, since no single machine function implements `'a -> 'a`. The Rust bootstrap punted on this and stored one call-site signature per function (`runtime_type_checker.rs:118-126`), warning when a polymorphic function is used at two concrete types. That shortcut is exactly what to avoid repeating.

## Lessons from the Rust bootstrap

`legacy-bootstrap/src/semantics/types/` is textbook Algorithm W with an **explicit substitution map**: `Type::Var(TypeVar { id })` is immutable and all state lives in `TypeSubst { map: HashMap<TypeVar, Type> }` (`type_subst.rs:5`), threaded as `&mut` through every inference call. `unify` (`type_subst.rs:60`) applies the substitution to both sides, matches structurally, and occurs-checks via `contains`. `TypeEnv` is a scope stack of `HashMap<String, TypeScheme>` plus the fresh-variable counter. Results land in side tables keyed by node id.

### Carry over

- **Hoist function signatures before checking bodies** — `hoist_fn_types` (`runtime_type_checker.rs:108`). Make it the only mode, not a phase-2 addition.
- **A final resolve pass** — phase 2 substitutes over the whole map at the end (`runtime_type_checker.rs:113-116`) so callers see concrete types. Build this in from the start.
- **The scope-stack environment**, which already mirrors `interp.ml`'s `env`.

### Change

- **Mutable unification variables instead of a threaded substitution.** `IVar of tv ref` with path compression lets `unify` mutate in place: no substitution parameter on every function, no `apply` at every node, no repeated chain-walking (today `unify` applies the substitution to *both* arguments on every recursive call). It also removes an entire bug class — phase 1's `TypeTable` records `ty.apply(subst)` at visit time (`type_checker.rs:492`) and is never re-substituted afterward, so it holds whatever was known then. Benign only because `debug_sink.rs:72` is its sole reader.
- **One checker, not two.** `type_checker.rs` and `runtime_type_checker.rs` are ~1,680 lines of near-duplicate inference, and the duplication exists only because `MetaAst` and `RuntimeAst` are distinct types. `bootstrap` has a single post-desugar AST.
- **No permissive fallbacks.** `env.lookup(name).unwrap_or_else(|| Type::Var(env.fresh()))` (`type_checker.rs:252-259`) and the struct escape hatches (`:271-280`) each inject an unresolved variable that something downstream must then compensate for. An unbound variable should be a hard error.
- **Keep `TypeScheme`, but add the value restriction.** `generalize`/`instantiate` (`type_utils.rs:73-100`) port over almost directly, and `TypeEnv::lookup` instantiating on every lookup is the right ergonomic. What is missing there is any value restriction — acceptable in the Rust bootstrap only because nothing yet exercises the unsound case.

### Latent issues worth not reproducing

- **Effect rows are carried but never unified.** `Type::Func` holds an `EffectRow`, but `unify`'s function case destructures with `..` (`type_subst.rs:84-87`) and unifies only parameters and return type, while `apply` clones the row through unchanged. Effects are really computed by a separate `collect_body_effects` walk. That is a defensible design, but storing the row inside the type implies a checking discipline that does not exist. If `bootstrap` grows effects, decide explicitly whether they participate in unification or are a separate analysis with their own representation.
- **Call-site signatures standing in for monomorphization.** `runtime_type_checker.rs:118-126` stores one concrete signature per `FnDecl` for codegen and, when a polymorphic function is called at two different concrete types, warns and keeps the first. Either monomorphize properly or do not generalize; the middle ground produced this wart.

## What shipped

| Step | Where |
|------|-------|
| Desugar span fidelity | `lib/desugar.ml` |
| `int` / `float` split | `lib/token.ml`, `lib/scanner.ml`, `lib/interp.ml` |
| Optional type syntax | `lib/token.ml`, `lib/scanner.ml`, `lib/parser.ml` |
| `('a, 'ann) node` | `lib/ast.ml` and everything downstream |
| Types and unification | `lib/types.ml` |
| Inference | `lib/typecheck.ml` |
| `--dump-types` | `bin/main.ml`, `lib/printer.ml` |
| Fixtures | `tests/types/inference/`, `tests/types/errors/`, `tests/reflection/` |

Notes on the parts that differ from the plan above:

- **Errors accumulate per top-level statement.** A statement that fails is dropped from the checked tree and checking continues; the tree is only returned when there are no errors at all, so a partial tree never escapes.
- **`unify` takes expected first, actual second**, and the message reads "Expected X, got Y" straight off that. Call sites that had it backwards produced inverted messages (`if (1)` reporting "Expected int, got bool"), which is worth watching for when adding rules.
- **`has_generic` and `match_generic` must agree.** One decides whether a definition is a specialization template, the other what its copy's types become, and both walk a type looking for `Generic`. If either stops short — they both used to skip a `Named`'s *arguments*, where an opaque container keeps its parameter — the result is a template that is never collected, or a copy that is collected and still generic. Neither shows up until a generic body contains something type-directed.
- **Generalization removes the function's own binding first.** `hoist` binds a function monomorphically so recursion works; leaving that binding in place while computing the environment's free variables makes every one of the function's own variables look free, and nothing is ever quantified. This cost an hour and is invisible until you test a function used at two types.

## Known gaps

- **`print` is variadic**, which no HM type describes. A call is checked structurally — the arguments are inferred and the call carries a signature built from them — and the *binding* is `() -> unit`, so referring to `print` as a value is rejected rather than yielding something unconstrained. What no type describes is the declaration, so `print` cannot be written in Cronyx. The intended answer is a `meta fn` expanding a call at compile time, which needs no type for the arity at all; the alternatives are a top type, trait objects, or a one-argument `print`.
- **No exhaustiveness check on `return`.** A function returning on only one path infers from the `return` it can see, while the evaluator yields `unit` when control falls off the end. The types are a promise the runtime does not keep.
- **`Generic` survives where nothing needed it concrete.** `Type_mono` copies a generic function or `impl` method per concrete type its call sites use, but only when the body contains something type-directed — an operator, a method, a literal. A function that merely moves values around keeps one copy and a `Generic` in its annotations, which is fine for the interpreter and will not be for codegen.
- **Uses before a function's declaration are monomorphic.** Generalization happens when the declaration statement is reached, so a call earlier in the same block sees the hoisted monomorphic type.
- **The same applies across declarations.** A call to a generic `impl`'s method from anything inferred before that `impl` pins its type variable permanently. The prelude hit this: `impl string`'s `split` calls `List.push`, and placing it above `impl List<T>` fixed `List__push` at `string`.

## Settled

**A dot is a call with the receiver passed first.** `x.f(y)` is `f(x, y)` when the receiver's type declares no method `f`, so a free function extends a type without an `impl` and without owning it. An `impl` answers first — otherwise whatever function a program happened to have in scope could shadow a method — and the fallback fires only after the type is found to have no method of that name, which keeps the rule to one direction.

It also settles the receiver's type where nothing else had. `[1, 2, 3].each()` has no owner to look in, because a literal's container is not chosen until something chooses it; unifying against the function's first parameter is what chooses it. So the fallback runs both when the owner has no such method and when there is no owner yet.

**A method call carries two names**, because neither pass can answer alone. Whether `xs.map()` reaches a method or a function is a typing question; what `map` names in the file it was written in is a loading one. So the node holds what was written and what the name resolves to as an ordinary function — the loader fills the second in by the same lookup it does for a reference, including a local of that name shadowing an import, and the checker uses the first to find a method and the second when there is none. Neither guesses.

That is what makes an imported function reachable through a dot: `import { map } from "…"` renames the declaration to `List#map`, and the resolved name carries the rename to where the fallback needs it.

**A trait may take type parameters, and a bound carries what it named them at.** `T: TryFrom<S>` is a `Types.Bound` holding the trait and its arguments, and a type satisfies it when an impl exists *at arguments that unify* — not merely when the trait's name appears. Every parameter is in scope while any bound is read, which is what lets `S` appear in `T`'s and `T` appear in its own. A bound may also say what the impl bound an associated name to — `Add<T, Output = T>` — checked alongside the arguments.

**A method without `self` is an associated function**, reached through the type rather than through a value of it — `T.from(source)` where `T` is a parameter, or `Counter.zero()` where it is a declared type. What stands under the receiver only has to carry the type; the receiver is dropped when the call is built, which `Type_mono` and `Resolve` learn from the registry.

Dispatch stays static: `Type_mono` copies the caller per concrete argument, so the call becomes a direct one to that type's entry.

**A variadic parameter is homogeneous, and the call site is what fills it.** `fn max(first: int, rest: ...int)` declares an ordinary `Array<int>` parameter; `Desugar` collects everything past the fixed arguments into an array literal, so nothing after that pass knows the call was written any other way.

Homogeneous is what makes it free. C#'s `params object[]` needs a universal supertype and a way back out of it; every argument here is the same `T`, so there is nothing to box and nothing to recover. A call that wants mixed types passes an explicit array, or several arguments.

Three rules. **Only the last parameter** may be variadic — anything after it has no boundary to be collected up to, and it is a parse error. **It always wraps**, so passing an `Array<T>` where a `...T` is declared makes a one-element array rather than being passed through; a spread would be a separate decision. And a function takes **either** a variadic parameter **or** a trailing block, since the block is itself appended as a final argument.

**A function is in scope for the whole block it was written in.** The checker hoisted declarations already, so a call above one type checked and then failed at runtime with *Undefined variable* — the types promising something the runtime did not keep. The interpreter now defines a block's functions before executing it, at every scope rather than only the top level, which is what the checker was already assuming.

Only functions. A `var` is a statement, and its initializer runs where it is written, so a function referring to one declared later is still rejected — by the checker, before anything runs.

**A function with a written `<T>` can call itself at another instantiation.** Its recursive occurrence is bound to the declared signature *generalized* rather than to `Types.mono`, so `depth<T>(n: Nested<T>)` reaching `depth` at `Nested<(T, T)>` checks. Inference cannot find that on its own, which is why it takes a written signature and why only the variables the author wrote are quantified — everything else about the signature is still being inferred and stays shared with the body. The row stays monomorphic, so recursion still contributes to the effects the function is inferred to perform.

A declared parameter is now the survivor when unification joins two variables. The scheme records an id, and an operator aliasing `T` to a fresh variable would leave that id pointing at nothing and the parameter silently unquantified.

**Two consequences in `Type_mono`.** A call a function makes to *itself* no longer makes its body type-directed: copying cannot resolve that call, since every copy asks for one more at a further type. And when a body genuinely does need a copy per type — an operator on the recursive payload — no finite set exists, so specialization is capped and the program rejected with a diagnostic rather than compiled forever. `tests/types/inference/errors/unspecializable_recursion` pins it.

**A variant may fix the type parameter, and matching it refines.** `Lit(int) -> Expr<int>` says what that constructor builds rather than leaving it the type applied to its own parameters, and `If<A>(…)` binds a variable the head does not mention. Building one gives the head it declared; matching one says the scrutinee's arguments *are* that head, which is how `return n` typechecks against `T` in the `Lit` arm.

`->` rather than a colon, because that is how Cronyx already writes a result and the colon after a variant label is what tells the parser it is reading fields.

The equation holds in the arm and nowhere else, so `Types.solve` produces it as a substitution and the arm is checked under that rather than under a mutated store. A sum whose variants declare neither parameters nor a head is checked on exactly the path it always was, and pays none of this.

The same solver answers exhaustiveness. A variant whose head cannot be the scrutinee's type is unreachable, so a match may leave it out — which is what lets `head(v: Vec<Succ<N>, T>)` have one arm — and an arm *for* one is rejected, since no value reaching it was built that way.

Koka is the usual tiebreaker and has no GADTs, so OCaml is the reference: the same HM-with-unification setting, and the same conclusion that this is checked against a written signature rather than inferred.

**The refinement is a substitution applied to what the arm sees** — its payload, its expected return type, the names in scope whose type mentions a refined variable, and what a written `T` means inside it. The store is untouched, so a constraint the arm places on anything else is ordinary and permanent, and neither a type nor an effect leaks out. See [GADT Refinement](GADT%20Refinement.md).

**Comparison operators are ordinary entries.** Their result type comes from the entry rather than being fixed to `bool` — see [Elaboration](Elaboration.md).

**`var x;` with no initializer is `unit`.** There is no null, so a declaration without a value cannot leave a hole to be filled in later. A record in particular can never be absent, which is the headache this avoids.

## Related work

- [Elaboration](Elaboration.md) — operators, indexing, and literals resolved from these types.
- [Effects](Algebraic%20Effects.md) — the row carried on every function type.
- [Static Params](Static%20Params.md) — what `Generic` becomes once monomorphization exists.
- [GADT Refinement](GADT%20Refinement.md) — how a match arm learns what a constructor says, and why it is not yet sound.
