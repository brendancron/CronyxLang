# Plan 02: Reflection and Splice

Scope: the Metaprocess subgraph's `code`, `meta`, `typeof` and `declof`
branches, Splice, the `# Splice` section and the Truths in
`internal-docs/CPS Migration.md`, and the three things its EffectHandler section
needs: a `meta` block in a trait body, `gen` of a `MethodSig` into it, and
`declof` of a static param. The decl cache, keys, per-node processing and
expected types belong to the Metaprocess-core slice (plan 01). `run` and
`effect_transform` belong to the Effects slice. Their interfaces are set out in
section 5.

Steps 1-8 build on today's walk (`metaprocess.ml`) and do not need core. Step 9
needs core's per-node typing. Every step ends with `dune build` and `dune test`
green, and a fixture that waits on a later step goes in `expected_failing`
naming that step.

---

## 1. Code map (today)

| Construct | Parse | Walk / lowering | Check | After check |
|---|---|---|---|---|
| `code(e)`, `code {…}`, `code fn` | `parser.ml:756-781` → `` `Code ``/`` `Code_stmts ``/`` `Code_decl `` (`ast.ml:445`) | `texpr` hands it to `h.code` without visiting its children (`metaprocess.ml:878`). `lower` (`:696-706`) turns it into `meta#code(k, "x", x, …)` with the captured node in `context.codes`. The native in `run` (`:475-495`) substitutes the bound names and converts with `Syntax.expr/stmts/decl` | only if it reaches Desugar: "'code' is only allowed inside a meta block." (`desugar.ml:215`) | — |
| `meta` statement | `parser.ml:908-921` → `` `Meta of 's list `` (`ast.ml:421`). There is no expression form | `tstmt` → `h.meta` (`:1007`) → `meta_stmt` → `run_meta` (`:2230`): walk the body, `lower`, `meta_program` (`:2466`), then `run` (`:463`) through `Compile.program` and the interpreter | the block, as its own program | — |
| `gen S` | `parser.ml:922-926` → `` `Gen of 's `` | `lower` (`:749-762`): `promote` (`:517`) and then `meta#emit(k, bindings…, promoted…)`. `emit_into` (`:452`) appends `substitute_all bound [captured]` to `context.current : Ast.stmt list ref ref` (`:449`). A bare name standing as a statement is spliced by its kind in `substitution.spliced` (`:291-304`) | — | — |
| fitting the generated code | — | scattered: top-level hoisting of declarations (`:3035-3042`); a module drops its statements and prefixes its declarations (`wake`, `:2434-2462`); "An impl cannot be generated inside a function body." (`:1991`); "A type's meta block can generate only its methods." (`instantiate_type`, `:2390`); an expression that is not one, through `literal_of` (`:85`) | — | — |
| `typeof(e)` | `parser.ml:750-755` → `` `Typeof `` (`ast.ml:441`, `'e reflect`) | the walk visits the operand (`:948`). The derive call is built as `typeof(X).shape` (`:2216`) | `typecheck.ml:2517-2540`: of type `Type` (`Types.ireflected`, whose fields are declared at `types.ml:1513-1524`). A bare name with no value is its declared type | `reflect.ml` folds `.name`, `.shape`, `.attrs` and `.doc` (`:208-225`) and rejects a bare `typeof` ("A type is not a value here"). It runs in `compile.ml:90-93`, between Resolve and Cps |
| `declof` | **does not exist**: no token, node or Ast.cx variant | — | — | — |
| `moduleof` | the loader rewrites it to `__moduleof` (`loader.ml:532-544`) | `lower` → the `meta#moduleof` native (`:700`, `:499`). **It re-enters the walk from inside a running block**, through `module_hook` → `module_record` → `wake` (`:2550`). This is the precedent for step 7 | — | — |
| type body members | `parser.ml:1430`, `:1490-1504` → `` `Type_members `` (`ast.ml:415`) | `types_of` (`:2844`) makes a comptime type. `instantiate_type` (`:2334`) runs its metas with `named` substituted, keeps the functions, and registers `Buf<4>` | — | — |
| trait | `trait_decl` (`parser.ml:1245-1297`): only `type X;` and `fn sig;` members. `trait_body` is not parameterised by `'s` (`ast.ml:280`) | standing impls carry `trait = Some name` (`:2730`). `w.traits` decides a bound from a value param (`:1341`, `:2646`) | `declare_impls` (`typecheck.ml:2850-2925`): "missing method" against `tb_methods` | — |
| reflected AST | `stdlib/compiler/Ast.cx` (`ExprKind` `:87`, `StmtKind` `:209`, `DeclKind` `:234`, `TraitDecl` `:289`, `MethodSig` `:313`). `stdlib/compiler/Printer.cx` | `syntax.ml`: `expr` (`:133`), `stmt` (`:228`), `decl` (`:261`), `method_sig` (`:367`). Readers `read_*` (`:565-835`; the MethodSig reader is inline at `:742-749`). `kind_of` (`:846`) knows Expr/Stmt/Decl/TypeExpr/List<Stmt>, **not MethodSig** | — | — |
| value → syntax (reify) | — | `literal_of` (`:72-119`): handles no `Value.Name` and no `Value.Span`. A `Name` bound for a type param becomes `` `Var n `` in `substitution.expr` (`:197-198`) | — | — |
| precheck | — | `precheck.ml:32-61`: `meta`/`gen` → `[]`, `code` → unknown, `Type_members` → a type plus an impl | partial | — |
| instances | — | `instantiate` (`:2091`): `copies` keyed by `(name, key)`, substitutes `named`, calls `bind_values` and then `walk_entry ~statics`. `reach` (`:1794`) adds to `deps`, and `program` (`:3064-3106`) emits only what `roots`+`deps` reach. That reachability check is today's Prune | — | — |

---

## 2. What changes, by file

- **`ast.ml`**: add three variants to the surface tree only. Every later stage loses them, which is the Truth "no reflection node".
  ```ocaml
  type 'e declof = [ `Declof of 'e * 'e static_arg list option ]  (* None: no <…> written *)
  type 's meta_expr = [ `Meta_expr of 's list ]
  type 's trait_members = [ `Trait_members of 's * 's list ]      (* the Trait_decl, then its meta blocks *)
  ```
  Add `expr declof | stmt meta_expr` to `expr_kind` and `stmt trait_members` to `stmt_kind`, but not to `desugared_*`. `reflect` stays in the typed stages until step 9, then leaves them.
- **`token.ml`/`scanner.ml:76`**: add `declof`.
- **`parser.ml`**:
  - `primary`, next to `Typeof` (`:750`): `declof(` then a qualified name (`a.b`) and, if `<` follows, `static_arguments s`. It must not require `(` after them, which the postfix loop at `:429-443` does. Then `)`.
  - `primary`: `meta {` → `` `Meta_expr (block s) ``, braces required.
  - `trait_decl` (`:1262`): `check s Token.Meta` → `declaration s` → accumulate. If any were found, build `` `Trait_members (Trait_decl…, metas) ``.
  - `Code_decl` accepts `Trait_members` (`:771`).
- **`stdlib/compiler/Ast.cx`**: add `ExprKind.Declof(Expr, Option<List<StaticArg>>)`, `ExprKind.Meta(List<Stmt>)` and `DeclKind.TraitWithMembers(TraitDecl, List<Stmt>)`. Mirror them in `syntax.ml` (both directions), `stdlib/compiler/Printer.cx`, `source.ml:178` (`--dump-code`), `printer.ml:117` and `loader.ml:605` (the `Declof` operand goes through `go`, so a qualified `util.f` resolves as at `:553`) and `:622` (`Trait_members` like `Type_members`, plus `declared_name` at `:324`/`:353`).
- **`syntax.ml`**: factor out `read_method_sig` (`:742-749`). Add a `Sig_node` to `kind` and `kind_of` (`Record (Some "…MethodSig")`) and `describe Sig_node = "a method signature"`. Add `to_method_sig`.
- **`splice.ml`** (new; after `syntax.ml`, before `metaprocess.ml` in dune's order): fragments, `fit`, and reify (section 3.1). `literal_of` moves here as `Splice.reify`.
- **`metaprocess.ml`**: `context.current` holds `Splice.fragment list`. A `decls` table goes next to `codes`. New hooks are `meta_expr` and `declof`, and `quiet` gets defaults for both. Add `comptime_traits`/`trait_copies` to `world`, and `instantiate_trait`. Every site that fits generated code calls `Splice.fit`.
- **`precheck.ml`**: `Meta_expr` → `unknown`; `Declof` → `unknown`; `Trait_members` → dropped (see trap T6).
- **`desugar.ml:215`**: `Declof` and `Meta_expr` get the same "only allowed inside a meta block" guard as `code`. This is defensive, because the walk removes both.
- **`reflect.ml`**: in step 8, a bare `typeof` builds the whole `Type` record. In step 9 the file is deleted, its builders live on in `Splice.type_value`, and `compile.ml:90-93` loses the stage.

---

## 3. Design

### 3.1 Splice

```ocaml
(* splice.ml *)
type fragment =
  | F_stmt of Ast.stmt          (* a quoted statement, or a Stmt/Decl/List<Stmt> value *)
  | F_expr of Ast.expr          (* `gen code(e)`, or an Expr value *)
  | F_sig of Ast.method_sig     (* a MethodSig value *)

type context =
  | Top                         (* entry top level: declarations hoisted (metaprocess.ml:3038) *)
  | Unit of string              (* a module's top-level meta: statements dropped, names prefixed *)
  | Body                        (* function or method body, block *)
  | Meta_program                (* a meta nested in a meta body: generated code is the outer block's *)
  | Expression                  (* a meta standing as an expression *)
  | Type_body of string         (* comptime type copy: functions only *)
  | Trait_body of string        (* comptime trait copy: signatures only *)

type fitted =
  | Stmts of Ast.stmt list
  | Expr of Ast.expr
  | Sigs of Ast.method_sig list

val fit : context -> Ast.span -> fragment list -> fitted
```

How `fit` treats each context:
- `Top | Unit _ | Body | Meta_program`: `F_stmt s` → `s`, `F_expr e` → `` `Expr e ``, and `F_sig` → "A method signature can be generated only into a trait body." `Body` also rejects an impl, with the message moved from `:1991`.
- `Expression`: it must be exactly one fragment, either `F_expr e` or `F_stmt { it = `Expr e }`, and the result is that `e`. Errors:
  - zero fragments: "A meta block standing as an expression generates one expression; this one generated nothing."
  - more than one: "…; this one generated N."
  - one that is not an expression: "…; this one generated a statement."
- `Type_body t`: `F_stmt` with `fn_parts`, using the message moved from `:2390`.
- `Trait_body t`: `F_sig` only, else "A trait's meta block can generate only method signatures." A name that clashes with one already in the trait is "Trait '%s' already has a method '%s'."

Fit errors are raised at the meta block's span, never at the `gen`. Reify errors (`reify_fn`, `reify_object`) are still raised while the block runs, at the `gen`. They are about promoting a value, not about fit (default D1).

**Classifying in `emit_into`** (`metaprocess.ml:452`) means looking at the captured statement before substituting it:

```ocaml
let fragments bound (captured : Ast.stmt) =
  match captured.Ast.it with
  | `Expr { Ast.it = `Code e; _ } -> [ F_expr (substitute_expr bound e) ]      (* gen code(1 + 2) *)
  | `Expr { Ast.it = `Code_stmts ss; _ } -> List.map (fun s -> F_stmt s) (substitute_all bound ss)
  | `Expr { Ast.it = `Code_decl d; _ } -> [ F_stmt (substitute bound d) ]
  | `Expr { Ast.it = `Var n; span; _ } when bound_kind bound n = Some Syntax.Sig_node ->
    [ F_sig (Syntax.to_method_sig ~fallback:span (Hashtbl.find bound n)) ]
  | `Expr { Ast.it = `Var n; span; _ } when bound_kind bound n = Some Syntax.Expr_node ->
    [ F_expr (Syntax.to_expr ~fallback:span (Hashtbl.find bound n)) ]
  | _ -> List.map (fun s -> F_stmt s) (substitute_all bound [ captured ])
```

Today `gen code(1 + 2);` leaves a `` `Code `` node in the emitted statement, because substitution skips quotes (`:225`). Desugar then rejects it, so the first case is a fix as well as a feature. A second native, `meta#emit_value(v)`, classifies a value with `Syntax.kind_of` the same way (3.4).

`current : fragment list ref ref`. `run_meta` returns `fragment list` and every caller fits it:
- `runtime_hooks.meta` (`:1983`) → `Body`, or `Top` at the root
- `run_meta`'s nested `meta` (`:2252`) → `Meta_program`
- `wake` (`:2451`) → `Unit prefix`
- `program` (`:3036`) → `Top`
- `derive` (`:2224`) → `Top`/`Unit`
- `instantiate_type` (`:2391`) → `Type_body`

After fitting, generated code is walked in the scope where it lands (`tblock h scope generated`, as at `:1994`). That is the diagram's "gen code → Metaprocess → Splice".

**Reify** (`Splice.reify : span -> Value.value -> Ast.expr option`) is `literal_of` with one addition: `Value.Name n` → `` `Name n `` (`ast.ml:175`). It is used only for spliced *data*, such as a `Type` record. `substitution.expr` keeps its own `Value.Name n → `Var n`` path, because the type param `E` → `Effect` rides on it (trap T1).

### 3.2 `meta` as an expression

- The walk: `texpr` gains `` `Meta_expr body -> h.meta_expr scope e ``. In `runtime_hooks` it does three things:
  1. `run_meta w ~statics ~runtime:scope ~outer:[] body`
  2. `Splice.fit Expression`
  3. `texpr h scope result`, which walks it where it lands
  
  `run_meta`'s own hooks get the same thing with `~outer` extended, as at `:2252`.
- `survey` (`:1117`) sets `meta := true` on a `Meta_expr`, so a function holding one is not `plain` (`:1365`). `contains_code` and `promote.children` pass a `Meta_expr` through. In `substitution` it is substituted like `` `Meta `` (`:390`).
- Evaluation order: the hook runs where `texpr` reaches it, left to right (the comment at `:851`). Use the `let` style for any new constructor with two children.
- Expected type: Splice returns the expression before it is processed, so core processes it with the expected type of the meta block's position (I2). `var xs: Set<int> = meta { gen code([1, 2]); };` is a `Set`.
- Precheck: `Meta_expr` → `unknown span`, the same as `code` (`precheck.ml:42`).

### 3.3 `typeof` spliced to the type

The settled order is: process the operand, then splice `typeof(e)` to the type. Under core:

```ocaml
| `Typeof operand ->
  let ty = Core.type_in w scope operand in      (* processed with a scratch deps set: T4 *)
  Splice.type_expr span ty field                (* surface literal, then processed like any child *)
```

- `Splice.type_value : Types.ty -> Value.value` builds the `Type` record from reflect.ml's builders (`shape_of`, `attrs_at`, `ref_of_ty`, `declared_order`), retargeted from typed nodes to `Value.value`. `Splice.type_expr` reifies it. A typeof that is the receiver of `.name/.shape/.attrs/.doc` splices only that field, as `reflect.ml:213-220` does, so run-time fixtures stay cheap and print the same.
- A bare `typeof(e)` is a `Type` value. Add `impl Display for Type` to `stdlib/meta/Reflect.cx`, writing `self.name`, so `print(typeof(t))` prints `int`. `tests/reflection/errors/not_a_value` becomes a `.txt` fixture.
- **A meta block sees the types of the run-time names around it.** Inside a meta body, the operand of `typeof` is never evaluated, so a run-time name of the enclosing body may stand there, and only there. In `run_meta`, a `Typeof e` whose reads meet `runtime` is spliced before `lower`, using `Core.type_in` on the *enclosing* scope. `meta print(d)` is still `dynamic_in_meta`.
  - Interim, before core (step 8): handle `Var x`, where x is a parameter or annotated local of the current entry. Substitute the written annotation, already instantiated (`t: T` → `t: int` by `substitute named`), giving `typeof(int)`. The checker's "bare name with no value is its declared type" path (`typecheck.ml:2518`) then answers it. An unannotated or compound operand is "typeof in a meta block reads only a parameter or annotated local until …". Replace that with `Core.type_in` in step 9.
- A bare generic function name under `typeof` (`typeof(pick).name`, `tests/reflection/typeof_generic`) is typed at its generic scheme and not instantiated: typeof is not a use, so no key is needed (default D2).

### 3.4 `gen` of a value: `gen handled(op)`

Today a `gen` statement's own call is quoted and never evaluated (`promote`, `:631-633`), so `gen handled(op);` emits a *call* to `handled`. The EffectHandler design needs it evaluated (Q1). Proposed rule: in `lower`, a `` `Gen { `Expr e } `` whose `e` is syntax-valued lowers to `meta#emit_value(e)` instead of being captured. An expression is syntax-valued when it is:
- a `Call`/`Static_call` to an entry whose declared return type head (`type_of`, `:1845`) is `Expr`, `Stmt`, `Decl`, `MethodSig`, `TypeExpr` or `List`-of-one-of-those, or
- a `Method_call` whose `as_function` entry declares the same.

`meta#emit_value` classifies the value with `Syntax.kind_of` → fragment(s). A bare meta-bound name keeps today's substitution path.

### 3.5 Meta blocks in a trait body, and `gen` of a MethodSig into it

- **`traits_of w p`** runs next to `types_of` (`:3006`). For each `Trait_members (Trait_decl (name, params, body), metas)` it records `w.comptime_traits` as `{ tr_name; tr_params : string list; tr_body; tr_metas }`. It also does `Hashtbl.replace w.traits name ()` (T2) and `known`. `declared_traits` (`:2656`) must see through `Trait_members` too.
- **When an instance is made:** when an impl naming a comptime trait is collected or registered (`collect` `:2818`, `register` `:2780`), before `standing_of`, so that `standing.trait` is the instance. The trait instance is made, and the impl's head is rewritten to `(instance, open_args)`. The Effects slice calls the same function for `handle<E>` (I5).
- **`instantiate_trait w tr args ~open_params span : string * Ast.type_expr list`**
  - An arg that is `Ty_name p` with `p ∈ open_params` (the impl's own type params) is an *open slot*. Every other arg is bound by `type_key`.
  - Name: `EffectHandler<Effect, String>`, or `EffectHandler<Effect, _>` with open slots (Q2). The instance's own params are the trait's param names at the open slots (`[R]`). The impl's args become those slots' args (`[Ty_name "R"]`).
  - Memoize in `w.trait_copies`. Before running, enter the name (as `copies` is at `:2134`) so that a trait meta naming its own instance terminates.
  - `named` maps each bound param → `Value.Name ty`. Each meta is `substitute named`'d, which turns `declof(E)` into `declof(Effect)`, then run with `meta_stmt w ~statics:[] ~runtime:S.empty ~outer:[]` and fitted with `Trait_body`.
  - The generated sigs are substituted with `named` again, so `TypeKind.Named("R")` becomes `String` when R is bound and stays `R` when R is open. This needs a type-level entry point to `substitution`: return `type_expr` as a fourth component and map it over `ms_params`/`ms_signature`.
  - Register `Trait_decl (instance, open_names, { tr_body with tb_methods = written @ generated })` through `register_hook` (`w.types`, `w.traits`).
- Written methods and generated ones coexist, and the written ones come first.

### 3.6 `declof`

The operand is a declaration name, optionally with its key written: `declof(greet)`, `declof(greet<int>)`, `declof(util.f<1>)`, `declof(E)`.

**Resolution** (`Splice.declof`, called from the walk's `declof` hook in `run_meta` and from the `meta#declof` native, both through one function `resolve_decl w name static_args span : Ast.stmt`):
1. `wake w name`.
2. If `name` is a function entry:
   - It has static params and `static_args = None`: "'greet' takes static parameters, so declof needs its key written: declof(greet<…>)." A function with none has the key `{}` and needs no `<>`.
   - `Some args`: go through `Core.Cache.process w ~use:`Reflect name key span` (I1). Interim: `instantiate w t args span`, which works for a plain generic function too, since it substitutes `named`. **Do not add to any `deps`.**
   - No static params: `walk_entry w e`; return `e.walked`.
   - Still `Walking` (declof of the function whose meta is running): "'%s' is still being metaprocessed, so declof cannot see it yet."
3. If `name` is type-level (`w.types` by `declared_of`): return it as written. If it is a comptime type or trait with args: return the instance (`instantiate_type` / `instantiate_trait`).
4. Otherwise: "'%s' is not a declaration." This covers a local, a parameter and a meta value that is not a `Name`.

**Static param** is substitution: an instance's or trait copy's `named` already rewrote `E` to `Effect` in the operand. That works because `Declof`'s operand is an ordinary `'e` that `substitution.expr` visits via `map_declof` (T1).

**Splice in a meta program** has two cases:
- **Static operand**, resolved when the walk reaches the `declof`, which is the diagram's order: store the processed stmt in `context.decls` (memoized by instance name) and replace the node with `meta#decl(k)`. The native returns a fresh `Syntax.decl stmt` on each call. Do not cache the Value, because programs mutate syntax objects (Reflection.md "Modifying Code").
- **Meta-bound operand** (`declof(n)` where `n` is a meta local holding a `Name`, which is what `effect_transform` has after reading `ExprKind.Call(Var(n), …)`): `lower` turns it into `meta#declof(n, [type args as TypeExpr values])`. The native calls `!declof_hook w name args span`, re-entering the walk from inside the block as `moduleof` does (`:499`, `:2552`). `run_meta` already saves and restores `current` (`:2270-2284`), so a nested meta that this triggers collects into its own list.

**Run-time code**: `declof` outside a meta block or a function only a meta block reaches is "'declof' is only allowed inside a meta block." That is the same rule and the same check as `code` (`desugar.ml:215`).

**Prune**: neither form adds to `deps`, `roots` or a standing's `reads`. So an instance made only for `declof` is in `w.instances` but not `reachable` (`:3064`) and is not emitted. If a later call reaches the same key, it is the same cache entry (`copies`), already walked.

**What comes back**: the instance's processed surface form, `e.walked`. Its meta blocks have been replaced by what they generated, its static params substituted, and its name is the instance's (`greet#0`). `gen`'ing it again under the same name is "'greet#0' is already declared."; the design renames it first.

### 3.7 A reflected value through `gen`

`code(e)`/`declof(x)`/a hand-built `Expr.of(…)` → `Value.Record (Some "…Expr", …)`. The value is taken apart and rebuilt by ordinary code. `gen v` → `emit_into`, or `emit_value` → `Syntax.to_*` → fragment → `Splice.fit` → walked where it lands → checked. Round-trip invariants to test:
- `Syntax.to_decl (Syntax.decl d) = d` modulo spans, for `Trait_members` and the new `ExprKind`s (`tests/meta/syntax/round_trip` extended)
- a `MethodSig` read from `declof(E)` and emitted unchanged is the written signature, attributes included (`@ctl`, `ms_attrs`)

---

## 4. Ordered steps

Each step ends with `dune build && dune test` green. "Fixtures" are new unless marked.

**Step 1: syntax only.** Covers the token, parser, the `ast.ml` variants, Ast.cx/Printer.cx, syntax.ml in both directions plus `read_method_sig`/`Sig_node`, source.ml, printer.ml, loader.ml and the desugar guards. The walk treats `Meta_expr`/`Declof`/`Trait_members` as "not supported" errors raised at their span (deleted in steps 3/6/5), and precheck erases them.
- Fixtures: `tests/meta/syntax/round_trip` extended with a `code meta {…}` expression, a `code trait T<A> { meta {…} }` and `code(declof(f<int>))`. Add `tests/meta/declof/*`, `tests/meta/splice/*` and `tests/meta/traits/*` from steps 3-7 to `expected_failing` now, each naming its step.

**Step 2: fragments and `Splice.fit`, as a refactor.** Add splice.ml and change `context.current` to fragments. The six fit sites move into `fit`, and `literal_of` moves to `Splice.reify`. Then fix `gen code(…)` (the first three cases of `fragments`).
- The existing fixtures are unchanged, especially `tests/meta/02_gen/*`, `05_order/15_gen_local`, `05_order/12_methods`, `06_modules/gen_export` and `03_derive/gen_in_helper`.
- Fixtures: `tests/meta/splice/gen_code_expr` (`meta { gen code(print(1)); }`), `gen_code_stmts` and `gen_code_decl`.

**Step 3: meta as an expression** (3.2).
- Fixtures: `tests/meta/splice/meta_expr` (`var x = meta { gen code(1 + 2); }; print(x);` → `3`) and `meta_expr_value_param` (in `fn f<n: int>()`, `return meta { gen code(n * 2); };`).
- Error fixtures: `splice/errors/expr_none`, `expr_two`, `expr_stmt` (a `gen var y = 1;` in expression position) and `sig_in_body` (step 4).

**Step 4: `gen` of a value, and MethodSig.** Covers `meta#emit_value` and the syntax-valued rule in `lower` (Q1).
- Fixtures: `tests/meta/splice/gen_call_value` (`fn two(): Expr { return code(2); } … var x = meta { gen two(); };`) and `splice/errors/sig_in_body` (a MethodSig generated at the top level).
- `tests/meta/02_gen/promote` must still print the same, because `twice` returns `int`, which is not syntax.

**Step 5: meta blocks in trait bodies** (3.5).
- Fixture `tests/meta/traits/meta_in_trait`: `trait Getter<T> { meta { gen sig_named("get"); } }`, where `sig_named` builds `MethodSig { name, params: [self], signature: { ret: Some(T) } }`. Then `impl Getter<int> for Box { fn get(self): int {…} }` and a call.
- `traits/per_instance`: two instances print in their meta, once each, in collect order, and a third `impl` at a key already seen prints nothing.
- `traits/open_param`: `type Picker<R>` … `impl Getter<R> for Picker<R>`.
- `traits/errors/stmt_in_trait` ("…only method signatures") and `traits/errors/missing_generated` (an impl lacking a generated method → the checker's "is missing method").

**Step 6: `declof` with a static operand** (3.6, interim cache).
- Fixtures under `tests/meta/declof/`:
  - `fn`, which prints `declof(greet)` and matches `DeclKind.Fn`
  - `keyed` (`declof(id<int>)`, whose params show `int`)
  - `trait` (`.methods` names)
  - `processed`, where the declof'd function's `meta` prints once and its generated body shows in the Decl, and a later call to the same key prints nothing more
  - `pruned`: a declof'd function with `meta print` and no call; check with `--dump-code` that it is not emitted (a `renderings` entry, `test_bootstrap.ml:1112`)
  - `static_param` (`fn f<T>() { meta { match declof(T).kind {…} } }` called as `f<Dog>()`)
  - `qualified` (`declof(util.f)`)
- Errors:
  - `declof/errors/unkeyed`, for a bare generic
  - `declof/errors/self` (Walking)
  - `declof/errors/not_a_decl`
  - `declof/errors/outside_meta`

**Step 7: `declof` with a meta-bound operand** (the `meta#declof` native, `declof_hook`).
- Fixture `tests/meta/declof/dynamic`: walk a quoted body's calls and declof each callee by its `Name`, the shape `effect_transform` needs.
- `declof/errors/dynamic_unknown`: a Name nothing declares.

**Step 8: EffectHandler end to end, and typeof in an instance's meta.**
- `tests/meta/traits/effect_handler`: the CPS Migration.md trait, `handled` and `takes_control` verbatim (T7 adjusts `str(E)`), `type Picker {}` with `impl EffectHandler<Effect, String> for Picker`, and direct calls `Picker.choose([1, 2], (x) => str(x))`. The `--dump-code` rendering shows the generated `fn choose(options: Array<int>, resume: (int) -> String): String;`.
- Then: bare `typeof` as a `Type` value (reflect.ml builds the whole record) and `impl Display for Type`. Flip `tests/reflection/errors/not_a_value` to `tests/reflection/typeof_value` (`.txt`: `int`) and move it from `error_cases` (`:657`) to `cases`.
- Interim run-time-param splice in `run_meta` (3.3).
- Fixture `tests/meta/params/typeof_param`, the brief's `helper`: `fn helper<T>(t: T) { meta print(typeof(t)); return t; } helper(1);` prints `int`.
- `05_order/errors/dynamic_in_meta` is unchanged.

**Step 9 [needs core]: Splice at processing, and Reflect gone.**
- The typeof branch becomes 3.3's `Core.type_in` + `Splice.type_expr`, at every node, run-time code included. declof goes through `Core.Cache.process ~use:`Reflect` and returns a checked instance.
- Remove `reflect` from `desugared_*`/`typed_*`/`resolved_*`. Delete `reflect.ml`, the `reflected_*` stage (Cps takes `resolved`) and `typecheck.ml:2517-2540`, and replace `Types.ireflected` with the record type `Type` declared in Reflect.cx.
- Every `tests/reflection/*`, `tests/core/arrays/basics`, `tests/core/tuples/typed`, `tests/meta/03_derive/*` and `05_order/07_type_mono` must print the same.
- New fixture `tests/meta/params/typeof_compound`: `meta print(typeof(t.field))` and `typeof(xs[0])`.

Out of this slice, though Reflection.md asks for it: `code`/`declof` in run-time code (`print(code(…))` at run time). With `Splice.reify` plus a `` `Span `` literal for `Expr.span` it is about 40 lines, and it flips `tests/meta/code/errors/outside_meta`.

---

## 5. Interfaces

### Assumed from Metaprocess-core (plan 01)

- **I1, the decl cache.**
  ```ocaml
  Core.Cache.process : world -> use:[ `Call | `Reflect ] -> string -> key -> Ast.span -> instance
  Core.Cache.key_of_written : world -> string -> Ast.expr Ast.static_arg list option -> Ast.span -> key
  ```
  - `key_of_written` raises the "write the key" error for `None` on a decl with static params, and returns `{}` for one without. Implicit static params (`fn id(x)`) are keyed positionally, in parameter order (D3).
  - `instance = { name; surface : Ast.stmt (* processed, meta-free, statics substituted *); typed : … }`. declof needs `surface`.
  - `` `Reflect `` must not record a use. Prune's roots are calls only.
  - An instance still in progress raises a distinguishable exception, so that declof can say "still being metaprocessed".
- **I2, per-node processing with expected types.** `Core.process_expr : world -> scope -> expected:Types.ty option -> Ast.expr -> Ast.typed_expr`. A `Meta_expr` and a `Typeof` are spliced first, and the result is processed with the *same* `expected`.
- **I3, operand typing.** `Core.type_in : world -> scope -> Ast.expr -> Types.ty`. It processes the operand into a scratch deps set that is discarded (T4), and works for the enclosing scope of a meta block (the run-time names in `scope`).
- **I4, processed decls carry no reflection node.** Core's Typecheck no longer accepts `` `Typeof ``/`` `Declof ``/`` `Code `` after step 9. The types enforce it.

### Needed by the Effects slice

- **I5** `Metaprocess.trait_instance : world -> string -> Ast.type_expr list -> open_params:string list -> Ast.span -> string * Ast.type_expr list`. It is what `handle<E>` (and `with H`) use to name `EffectHandler<E, R>` and its instance.
- **I6** `var ret = meta { gen effect_transform<E, H>(code { body }); };` needs three things:
  - meta as an expression (step 3)
  - `gen` of a syntax-valued *static* call evaluating it (step 4, Q1)
  - instantiation of `effect_transform<Ask, Five>` from inside the block, which is allowed because both args are types, not meta values (`static_call`'s check at `:2018-2037` looks only at meta-scope reads)
  
  `effect_transform<E, H>(body: List<Stmt>): Expr` must return one `Expr`.
- **I7** A `code { … }` whose last line is an expression without `;` (the run body's value `"hehe"`) quotes as `List<Stmt>` ending in that `Expression` statement (D4). `effect_transform` reads the last statement as the run's value.
- **I8** `declof` of a callee by its `Name` (step 7), and `gen` of the transformed `Decl` under a new name, which is ordinary declaration gen.
- **I9** A `meta` block in a trait body runs once per trait instance, with E/R bound. `declof(E)` resolves to the bound trait. A generated `MethodSig` is spliced into the instance (step 5). E is unbounded, so a non-trait E fails in the meta at the instance that named it, as CPS Migration.md says.

---

## 6. Risks and traps found in the code

- **T1. Name reify vs type-param substitution.** `substitution.expr` (`metaprocess.ml:191-199`) turns a bound `Value.Name` into a `` `Var `` *only because* `literal_of` returns `None` for names. Adding `Name` to `literal_of` itself would make `declof(E)` and `typeof(S)` substitute to a `Name` literal and break `05_order/07_type_mono`. Keep the Name case in `Splice.reify` only, and never call it from substitution.
- **T2. The trait table decides a bound from a value param** (`:1341`, comment `:2646`). A comptime trait missing from `w.traits` turns `<H: EffectHandler<E, R>>` into a static value parameter.
- **T3. `emit_into`'s collector is shared and re-entered.** `wake`, `module_record`, `instantiate_type`, nested metas and now `meta#declof` all run `run_meta` while another block is collecting. Every new caller must save and restore `context.current`, as `:2270-2284` does, including on `Failed`.
- **T4. Reflection must not count as a use.** `typeof(f(x))` and `declof(g<int>)` walk their operand, and the walk's hooks add to `deps` (`reach` `:1801`, `static_call` `:2040`). Give the operand a scratch `deps` and drop it, or Prune emits instances nothing calls. Today's run-time `typeof(f(x))` already leaks this way; step 9 fixes it.
- **T5. `typeof` in a meta block is the only place a run-time name may stand.** The splice has to happen *before* `lower`/`Compile.program`. Otherwise the checker reports "Nothing named 't' is a value or a type" (today's failure) instead of `explain`'s `dynamic_in_meta` (`:1739`).
- **T6. Precheck of a comptime trait.** If the trait is erased with only its written methods, every `impl` of it fails "is missing method 'choose'", which the meta block would have made right. Drop the trait entirely in precheck: an impl of it is then "Unknown trait", which `partial` ignores (`typecheck.ml:2885`). The strict check sees the instance.
- **T7. The design's `str(E)` does not check.** In the EffectHandler meta block (CPS Migration.md:120), a type param is written by name and is not a value in a meta block (Meta Scope and Instantiation.md:66-69), so `str(Effect)` is "Nothing named 'Effect' is a value". The whole block fails to check even on the trait path. The fixture must say it another way, e.g. `fail("…is not a trait")` or a `Name` built from `declof(E)`. This is for the Effects slice to settle in its own fixture.
- **T8. A syntax value must be fresh on every call.** Programs mutate `Expr`/`Decl` records (`call.args[0] = …`), so `meta#decl(k)` rebuilds with `Syntax.decl` each time rather than caching the Value.
- **T9. `kind_of` misses an empty `List<Stmt>`** (`syntax.ml:855`, `count > 0`). The explicit `Core.list` case in `spliced` (`:296`) is what covers it. Keep that case first in `emit_value` too.
- **T10. OCaml evaluates constructor arguments right to left** (`:851-855`). A new `texpr`/`tstmt` case with two walked children must bind them with `let`, or the order of compile-time output changes.
- **T11. A declof'd instance's name is mangled** (`Ast.generated [ name; i ]`, `:2133`). It contains `#`, which `as_name` rejects (`code/errors/not_a_name`). Renaming has to build a fresh Name from a string, not edit this one.
- **T12. The instance name of an open trait is not unique by display.** `EffectHandler<Effect, _>` is shared by every impl that leaves the same slots open, which is right: one trait, a param per open slot. But the impl's own param name must be substituted into the instance's param, never shared by name.
- **T13. A generated method's types are substituted after the run.** `handled` writes `"R".as_name()`, and only the second `substitute named` (3.5) makes it `String` for a bound R. Substituting the metas alone is not enough, because the generated text is produced by the block, not written in it.
- **T14. `--dump-code` and diagnostics show trait instance names with spaces and `<…>`**, as type copies already do (`Buf<4>`, `05_order/errors/distinct_instances`). `source.ml` prints them unquoted.

---

## 7. Questions (only those that change the base)

- **Q1. Does `gen f(x)` emit the call or the value?** Today a `gen`'s own call is emitted, not evaluated (Metaprocessing.md "A statement's own call is never evaluated whole"). CPS Migration.md writes `gen handled(op);` and `gen effect_transform<…>(…)` meaning the value.
  ```cronyx
  fn two(): Expr { return code(2); }
  meta { gen two(); }      // today: emits `two();`   wanted: emits `2;`
  ```
  - (a) Decide by the callee's declared return type: a syntax type (`Expr`, `Stmt`, `Decl`, `MethodSig`, `TypeExpr`, a `List` of one) means evaluate. Everything else is quoted, so `gen print(x)` is unchanged.
  - (b) Decide by the checked type. This needs the `gen` operand checked speculatively under `partial`.
  - (c) Make users write `var s = handled(op); gen s;`, which changes the design doc.
  
  **Recommend (a):** it uses what the walk can already see (`type_of`, `:1845`) and leaves every existing fixture as it is.
- **Q2. A trait instance with an open param.** In `type Picker<R> impl EffectHandler<Effect, R>`, R is not known when the meta block runs.
  - (a) Open slots: the instance `EffectHandler<Effect, _>` keeps `R` as its own param. The block's `"R".as_name()` refers to it, and only bound params are substituted.
  - (b) Require every arg bound, so the generic `Picker<R>` of CPS Migration.md:233 cannot be written.
  
  **Recommend (a).** It is what makes the design's literal `"R"` correct for both the bound and the open case.

### Defaults (one line each)
- **D1.** Reify errors stay at the `gen` (they come from promoting a value), and only fit errors move to Splice.
- **D2.** `typeof(generic_fn)` with no key types the bare scheme, as `typeof_generic` shows today, and makes no instance.
- **D3.** `declof` of a function with implicit static params takes their key positionally, in parameter order.
- **D4.** A trailing value in `code { … }` quotes as a final `Expression` statement, with no new `ValuedBlock` quote.
- **D5.** `meta` as an expression requires braces. `meta f()` in expression position is a parse error.
- **D6.** `declof` of a plain type, trait or effect returns it as written. Of a comptime one with args, it returns the instance.
- **D7.** A trait instance is made when the first impl naming it is collected (source order), so its meta's output comes at that point.
