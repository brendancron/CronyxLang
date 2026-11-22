# Plan 01 — Metaprocess core

Scope: `internal-docs/CPS Migration.md` — the phase diagram, Metaprocessing Truths, Expected
Types, Recursion, Non-termination, Desugar and Resolve. Out of scope, owned by other plans:
Reflection/Splice of `typeof`/`declof`/`code`/meta-as-expression, `EffectHandler`/`run`/
`effect_transform`, the Compile path, stdlib and fixture migration. Precheck stays as it is.

All line numbers are against `main` at d418029.

## 0. Defaults assumed (one line each)

- **D1** Plain generic *types* (`type Box<T> { … }`) stay parametric in `Types.declarations`; only
  functions and methods are instances. A type with a value param or meta members is instantiated
  per key, as `instantiate_type` does today (metaprocess.ml:2334). (See Q3.)
- **D2** Same-key self-recursion follows the doc literally: a call into a `Walking` instance sees only
  the written signature. `04_recursion`/`05_mutual_recursion` then need `: int` / `: unit` written.
- **D3** A key is read at the call once the call's written signature has been unified with the
  processed arguments and the expected type. A variable still open there is an error (Q2).
- **D4** An unannotated parameter is rewritten at collect time into a written static param with an
  unwritable name (`Ast.generated ["implicit"; "0"]`), so implicit and written params take one path.
- **D5** Instance at key `{}` keeps the declaration's own name (and `Ast.impl_method_name` for a
  method). Other keys are named `Ast.generated [decl; n]`, as `instantiate` (metaprocess.ml:2140) and
  `Type_mono.copy_for` (type_mono.ml:257) do today. Runtime messages and fixtures keep their names.
- **D6** Display/Debug: `Builtins.written` (builtins.ml:241-266) finds `impl Display` by name at run
  time. Until Display goes static (Stdlib plan), Prune keeps the `{}` instance of `Display.fmt` /
  `Debug.debug` for every type the processed program constructs. This is the one root added by name.
- **D7** Desugar and Resolve jobs the doc does not list go into the checker arm of the node that holds
  them: attribute recording, named-handler lookup, `New_generic`→`New`, "`code` outside meta",
  `__moduleof`, destructuring (`Desugar.bound`), `Match_expr`/`Run_expr` hoisting, compound
  assignment, `Array_len`/`Str_get` primitives, `__upcast`.
- **D8** Errors: the walk accumulates type errors per root statement, as `check_with` does today
  (typecheck.ml:4778-4785). An instance that fails is marked `Failed`. A later call to it is typed
  from its written signature and is not reported again.

## 1. Code map

### Driver and order
| Where | Today | Change |
|---|---|---|
| pipeline.ml:28 `metaprocess` | `Metaprocess.program` → surface `Ast.program` | Returns the processed program (`Ast.processed_stmt list`, §2.1). `on_code` gets a printer for it. |
| pipeline.ml:47 `whole` | Precheck, then walk, then `Compile.program` | Precheck, then walk (which checks), then `Compile.back` (Reflect→CPS→Verify). `merged` (pipeline.ml:37) unchanged. |
| pipeline.ml:57 `front` | walk only, surface out | Processed out. `test_bootstrap.ml:1254 run_prelude_walk` greps `Source.program`, so it needs `Source.processed`. |
| compile.ml:15 `under_root` | wraps root statements as `__root(() => …)` | Moves to `Metaprocess.program` at the program→stmt edge. Precheck still calls it (precheck.ml:163). |
| compile.ml:58 `program` | Desugar→Typecheck→Type_mono→Resolve→Reflect→Cps→Verify | Becomes `back : processed_stmt list -> cps_stmt list` = Reflect→Cps→Verify. Desugar, Typecheck, Type_mono and Resolve leave it. |
| bin/main.ml `--dump-types` | `on_types : typed_stmt list` | `on_types` takes `processed_stmt list`, printed by `Printer` (printer.ml, which prints `For` at :243). |

### metaprocess.ml (3108 lines)
| Where | Today | Change |
|---|---|---|
| :443 `context`, :452 `emit_into`, :463 `run` | gen table; runs a block via `Compile.program` (:464), i.e. a whole fresh check | Step 4: wrapped in `Typecheck.nested`. Step 9: `run` takes an already-processed block plus the closure of instances it reaches, and calls `Compile.back` + Interp. |
| :517 `promote`, :682 `lower` | `gen`/`code` → `meta#emit`/`meta#code` calls, before the block is compiled | Kept. Lowering still happens before the block is processed, so the quoted code is never checked. |
| :817-1087 `hooks`, `texpr`, `tstmt` | the syntactic walk, children left to right | Not the driver any more. Kept as a syntactic utility for `substitute*`, `survey`, `reads_of`, Precheck's `erase` (precheck.ml:140) and `lift`. |
| :1093 `survey`, :1130 `contains_code`, :1361 `instantiated`/`plain`, :2769 `note_meta_methods`, world `meta_methods` | decides whether a function is "plain" (checked once, generically) | Deleted. Every declaration is processed at a key. |
| :1198-1230 `state`, `entry`, `standing`, `world` | entries by name, `copies` (name,keystring)→copy, `standing` impls/handlers, `comptime_types`, `type_copies` | Replaced by `decls`, `cache` and `instance` (§2.2). `standing`/`ready` (:1288)/`standing_of` (:2689)/`walk_standing` (:2748) deleted (task 5). |
| :1421-1558 `value_of_type`, `type_key`, `key_of`, `fold` | the walk guesses keys and types without the checker | `type_key`/`key_of` are replaced by `Key.of_types` over checked types. `fold`/`structural_eq` stay for static value args (`static_value` :1640). |
| :1686 `substitute_values`, :1726 `bind_values` | binds static values in the copied body | Kept, used when an instance with value params is made. |
| :1794 `reach`, :1805 `walk_entry`, :1833 `type_of`, :1853 `walk_method`, :1875 `reach_method`, :1895 `reach_impl`, :2048 `implicit_call` | reachability by name; method reach from a guessed receiver type; trait impl "reached whole"; implicit type args from `type_of` | Deleted. Reaching is the checker's call branch asking the cache, and a method is reached by reference. Coercion reaches the trait's slots (§2.5). The "Cannot tell which 'x' this calls" error (:1975) goes, because the receiver's type is known. |
| :1904 `runtime_hooks` | per-node hooks for the walk | Becomes the `Typecheck.walk` record (§2.3). |
| :2006 `static_call`, :2091 `instantiate`, :2165 `check_static` | a function taking a static value, instantiated by string key; the type arg must be `Ty_name` (:2131 "needs a named type here") | Merged into `Cache.instance` with `Key.t` (§2.2). Type args become any concrete `Types.ty`. A type param in the body is substituted with a `type_expr` printed from the `ty` (new `Types.to_type_expr`). |
| :2184 `meta_stmt`, :2192 `derive`, :2230 `run_meta`, :2466 `meta_program` | runs a block: re-walks its deps, gathers types + standing + walked bodies, checks them all again | Step 4: kept, isolated. Step 9: the block body is processed in walk mode against the shared cache. `meta_program` becomes "the instances the processed block references, transitively" (`instance.deps`). |
| :2287 `generic_new`, :2334 `instantiate_type` | types with a value param or meta members (`Buf<4>`) | Kept under D1, keyed by `Key.t`, stored in the same cache under a `Type` decl. |
| :2434 `wake` | runs a module's deferred meta the first time a name of it is asked | Kept. Called from the `decl` hook before lookup. |
| :2780 `register`, :2818 `collect`, :2844 `types_of` | registers written and generated declarations | Kept. Each also calls `Typecheck.declare_incremental` for type-level statements (traits, types, effects, impl signatures), so a generated `impl` is declared when it is registered. |
| :2900 `lift_comptime` | lifts a local function taking a static value to the top level; renames local types `owner#T` | Function lifting is deleted: local instances are emitted in place (§2.6). Type renaming stays, but goes by the owning *instance* name (trap T7). |
| :2972 `program` | the driver; reaches `__root` plus `Resolve.synthesized` (:3012), slots, `reachable` mark (:3064), `emit` (:3076) | Rewritten (§2.7, §2.8). `Resolve.synthesized` and its use at :2501 go: `__is_less` & co. are reached by the binop branch's own call. |

### typecheck.ml (4853 lines)
| Where | Today | Change |
|---|---|---|
| :16-20 `policy`, `current` | strict/partial | Kept. Precheck uses partial and the walk uses strict. |
| :45-74 `top_row`, `deferred_rows`, `expected_lambda`, `dynamic_rows`, `root_argument` | module globals | `expected_lambda` is replaced by the `?expected` argument (§2.4). The rest are session state: reset once per session and saved by `nested`. |
| :85-118 `checked_expr/stmt` | infer_ty-annotated superset of the typed AST | Kept as the in-flight tree. Walk mode builds `processed`-shaped nodes in it, with no `Bound_call`, `Compound`, `Index` or `Collection_lit` left. |
| :120 `env`, :382 `lookup` | `name → scheme` | Binding becomes `Scheme of scheme \| Decl of Decl.t`. In walk mode `lookup` of a `Decl` calls the walk's `instance`. |
| :162-310 `ctx_*` tables | program-global declaration tables | Stay global, and only grow during a session. `scoped_declarations` (:315, used at :3643) must not restore in walk mode (trap T2). |
| :355 `reset_effects`, :4749 `check_with` (`Types.reset` :4752) | reset everything per check | Split into `Session.start` / `declare` / `finish` (deferred-row and unhandled-effect errors, :4787-4840). |
| :1002 `coerced` | builds `Coerce(e, trait, slots)` with a dispatch per slot | Walk mode builds `Object` directly. Each slot is `Cache.instance` of the impl method at the value's key, moved from resolve.ml:201-262. |
| :1440 `dependency_order`, :3662 `infer_in_order`, :3746 `generalize_*` | SCC order plus generalization | Whole mode (Precheck) only. Walk mode goes in source order, and a callee is processed on demand. |
| :1633 `name_implicit_params` | — | Replaced by D4. |
| :1854 `Call` | args inferred against the callee's instantiated type; variadic special case | Becomes the call branch (§2.5). It takes variadic collection from desugar.ml:174. |
| :1952, :2000 `Static_call` | type-args instantiate the scheme | Call branch, with the written args as part of the key. |
| :2066-2483 `Method_call` | owners, `receiver_of` (:535), in-scope traits, UFCS fallback, `Bound_call` (:2334) for an unpinned receiver, `Dyn_call` (:2330) | Owner/UFCS/in-scope logic kept. A receiver whose head is still a variable is an error in walk mode ("ambiguous receiver", already `tests/core/traits/errors/ambiguous_receiver`). `Bound_call` is never built. |
| :1792 `Binop`, :1765 `Unop`, :1796-1829 `Compound*`, :2726 `Index*`, :2541 `Collection_lit` | typed here, lowered in Resolve | Lowered here (§2.5). |
| :2484 `Lambda` | reads `expected_lambda` | Reads `?expected`. Stays monomorphic. |
| :2518 `Typeof` | annotates | Unchanged here. Splice is Reflection's (§5). |
| :3529 `hoist` | binds every fn/method signature as a scheme | Walk mode binds `Decl`s instead (written signatures live in `Decl.t`). |
| :3843 `For_in` | uses `Desugar.fresh/pulled/indexed` (:3845-3859) | Uses `Lower.*` (step 2). |
| :3880 `Fn` stmt | checks the body and generalizes | Walk mode registers a local `Decl` and leaves a slot (§2.6). |
| :3939 `Impl_decl` stmt | checks every method | Walk mode: nothing to check, since methods are decls. Output is no statement. The Display row check (:3980) moves to instance completion. |
| :4531 `resolve_expr/stmt` | infer→ty for the whole tree | Run per root statement at its end (zonk). Instance bodies are zonked at the end of the root statement that reached them (trap T4). |

### Other passes
| Where | Today | Change |
|---|---|---|
| desugar.ml:166-307 | `__moduleof` error :170; variadic :174; `New_generic`→`New`; code-outside-meta; `Attributed`→`decl_attrs` :228; C-for :241; named handlers `clause` :257 | Module deleted. C-for goes to Parser via `Lower` (step 2). The rest go to the checker (step 3, D7). |
| type_mono.ml (765) | copies generic bodies; `depth_limit` :674; `refuse_captures` :599; arm-referenced generics stay generic | Deleted (step 7). |
| resolve.ml (723) | `record` tables :5-61 (read by verify.ml:206,232); operators :170; coercion :201; `Bound_call` :267; collection :285; index :312; `Run_expr`/`Match_expr` hoisting; impl flattening :669 | Step 4: run per root statement. Step 6: folded into the checker, and the tables move to `Typecheck` readers (`is_trait`, `methods_of`). Module deleted. |
| reflect.ml:38,122-192 | reads `Desugar.decl_attrs` and `Typecheck.ctx_*` after the check | Reads `Typecheck.decl_attrs`. Stays a back-end pass until Reflection moves it into Splice. |
| precheck.ml:162 | `Desugar.program (under_root (erase p))` → `Typecheck.check ~policy:partial` | `Typecheck.check ~policy:partial (Compile.under_root (erase p))`. Same behaviour. |
| parser.ml:1160 | builds `For` | Builds the lowered block (step 2). |
| syntax.ml:238, :695 | `For` ↔ `std/compiler/Ast` value | :695 lowers via `Lower.c_for`. :238 has no `For` arm. |
| source.ml:272, printer.ml:243, loader.ml:722, precheck.ml:98, metaprocess.ml:325,772,1036,1183,2938 | `For` arms | Removed. |

## 2. Target design

### 2.1 Stage types (ast.ml)
- `Ast.loops` (:516) loses `` `For ``. `stmt_kind` keeps `` `For_in `` (whether a sequence is indexed or pulled is a type question).
- `desugared_expr/stmt` (:563-594) deleted. Typecheck consumes surface `Ast.expr/stmt`. The delta it
  newly meets is `Attributed`, `Import`/`Global_import` (dropped), `Meta`/`Derive`/`Gen` (walk hook),
  `Type_members` (already split by `types_of`), `Handler_decl`/`Named` clauses, `Code*` and
  `New_generic`.
- `typed_*` (:596) and `resolved_*` (:631) merge into **`processed_expr/stmt`** = today's
  `resolved_expr_kind` + `` `Typeof `` (resolved already has `reflect`) with `Types.ty` annotations.
  `Reflect`/`Cps`/`Verify` change only their input type name. `bound_calls`, `coercions`,
  `compound`, `indexing`, `collection` and `method_defs` are absent from it, which is what stops the
  back end from meeting an unlowered call. `dispatch.dp_instance` (:335) goes.
- Truths as types: processed has no `Meta`/`Gen`/`Code` (no `meta_blocks`/`quote`), is annotated
  (`Types.ty`), and is monomorphic. That last one is checked by `Verify` refusing `Types.Generic`
  (new check, ~10 lines in verify.ml:45).

### 2.2 Declarations, keys, cache (new `decl.ml`, `key.ml`; cache in metaprocess.ml)
```ocaml
(* key.ml *)
type arg =
  | Type of Types.ty                      (* concrete: no Generic, no open row tail *)
  | Value of Ast.expr * string            (* literal and its shown form, from static_value :1640 *)
  | Row of Types.row                      (* a row static param, closed *)
  | Handler of string * Types.ty          (* effect label -> handler type; Effects plan fills *)
type t = (string * arg) list              (* declared order: impl params, written, implicit, rows *)
val show : t -> string                    (* "{T = int}", diagnostics and cache key *)
val of_vars : (string * Types.infer_ty) list -> (t, string list) result   (* Error = unsettled names *)

(* decl.ml *)
type kind =
  | Fn of { params : Ast.param list; sg : Ast.signature; body : Ast.stmt list; attrs : Ast.attr list }
  | Method of { impl : (string * Ast.type_expr list) option * string * Ast.type_param list;
                def : (Ast.stmt, unit) Ast.method_def }
  | Type of Metaprocess.comptime_type     (* D1 *)
type t = { name : string; kind : kind; static : Ast.static_param list;  (* after D4 *)
           span : Ast.span; scope : Typecheck.env option  (* defining env; None = top level *) }

(* metaprocess.ml *)
type state = Walking | Done | Failed
type instance =
  { decl : Decl.t; key : Key.t; name : string                      (* D5 *)
  ; mutable state : state
  ; mutable ty : Types.infer_ty    (* written signature while Walking; full type after *)
  ; mutable body : Typecheck.checked_stmt option     (* zonked into [processed] at its root's end *)
  ; mutable processed : Ast.processed_stmt option
  ; mutable deps : S.t                               (* instance names its body references *)
  ; mutable surface : Ast.stmt                       (* spliced surface copy, for meta_program (steps 4-8) and declof *) }
cache : (string * string, instance) Hashtbl.t        (* (decl name, Key.show) *)
```
`world.entries`/`copies`/`instances`/`standing`/`comptime_types`/`type_copies` (:1230-1260)
collapse into `decls : (string, Decl.t) Hashtbl.t` plus `cache`. The other world fields stay:
`known`/`unknown` (generated-name ordering), `units`, `vars`, `declared`, `generator`.

`Cache.instance w ~span decl key`:
1. hit → return it (`Walking` included).
2. miss → make `{state = Walking; ty = written decl key}` and insert it *before* processing. That is
   the recursion guard, and Non-termination is not guarded (no depth limit).
3. Substitute type params in the body (`Types.to_type_expr`) and bind value params (`bind_values`
   :1726). Then `Typecheck.walk_body` the body in the decl's defining env, with the params bound and
   `ret`/`row` taken from the key.
4. `state <- Done`, `ty <- IFn(params, inferred ret, inferred row)`. On a `Located` error,
   `state <- Failed` and the error goes to the root statement's error list (D8).

`written decl key` builds `IFn` from the written annotations under the key. An unwritten parameter
type is impossible after D4. An unwritten return or row is a fresh variable flagged `from_written`.
At a call into a `Walking` instance, unifying against a flagged variable raises
*"'f' is still being metaprocessed and its signature leaves its return type to inference; write it."*

### 2.3 Typecheck drives, Metaprocess hooks
`Typecheck` gets a hook record, threaded on `ctx`. It is the successor of `runtime_hooks` (:1904):
```ocaml
type walk =
  { decl : string -> Decl.t option                       (* calls Metaprocess.wake first *)
  ; instance : span -> Decl.t -> Key.t -> instance_view  (* name, ty, state *)
  ; meta : env -> Ast.stmt -> Ast.stmt list              (* Meta/Derive: run, return generated *)
  ; register : Ast.stmt -> unit                          (* generated declaration *)
  ; splice_expr : expected:Types.infer_ty option -> Ast.stmt -> Ast.expr   (* Reflection plan *)
  ; generic_new : span -> string -> Ast.expr Ast.static_arg list -> string }
val whole : walk option   (* None: today's algorithm, used by Precheck *)
```
Walk mode is `ctx.walk = Some w`:
- `Var x` where `lookup` gives `Decl d`: the call branch handles it (§2.5). Used as a value, the key
  comes from `?expected`, then from written `<…>`, and otherwise the error is
  *"'helper' is generic and its static params are not settled here; write them or give it a type."*
  `var f = helper;` gets that error.
- A statement list is a fold in source order: each statement's output list is spliced in, so
  `infer_block` becomes `concat_map`. `Meta`/`Derive` → `w.meta env s` → generated statements,
  declarations `register`ed and hoisted as in metaprocess.ml:3036-3040, then each checked in this
  env (Splice into a statement position). `Gen` outside a block keeps the error at :3043.
- Undefined names: walk mode records them in `world.unknown` (as `note_unknown` :1389 did) and
  continues with `unknown_ty`. The error is raised either when `register` sees the name (*"used
  before the meta block that generates it"*, :2789) or at the end of the walk (*"Undefined
  variable"*). That keeps `17_gen_before`/`18_gen_before_top` and `types/errors/undefined_variable`.

### 2.4 Expected types
`infer_expr ?expected env ctx e`. The sources are:
- `Var_decl` annotation (:3785), sent through `under_root`'s `?ret` (compile.ml:33).
- `Return` → `ctx.return_type`.
- Call args → the callee's written param types under a key whose unsettled params are fresh
  variables. That is the doc's "known part passed down, unknown left open", and HM gives it for free.
- `New` fields → `Types.fields_of` (types.ml:1480). Variant payloads too.
- `Field_assign`/`Index_assign` → the field or element type.

A child with an expected type is checked against it with `unify expected actual` at the node,
which keeps the "Expected X, got Y" order (Type System.md). The consumers that change behaviour
are these:
- `Collection_lit` with an expected head `H` → `H`'s `FromArray` container (registry `container`),
  with no `Collection` kind var. Without an expected type, today's `Collection` var defaults to
  `Array` at zonk (types.ml:1436).
- `Lambda` params are typed from the expected `IFn`. This replaces `expected_lambda` (:63, :1901,
  :2140, :2485).
- A trait-typed expected type → `coerced` (replaces `check_against` :2779's special case).
- A generic `Var` → key from expected.

Ordering rule (doc): within a call the callee's declaration is read before the args. Args go left
to right, with `settle_before` (:1889) so a lambda arg sees earlier args.

### 2.5 The call branch
Calls, `Static_call`, `Method_call`, `Binop`/`Unop`, `Index`/`Index_assign`, `Compound*` and
`Collection_lit` all go through one function:
```ocaml
call_branch : span -> target -> written_static:static_arg list -> args:Ast.expr list
           -> ?receiver:checked_expr -> ?expected -> checked_expr
```
1. **target.** A `Decl` from the env. For a method, the receiver is checked first, then its head
   gives `Registry.method_entries`/`receiver_of` (:535), then the impl's `Method` decl. For an
   operator, both operands are checked first. A primitive pair whose `Registry.find` gives
   `Primitive` builds `Binop` and stops there. Otherwise the entry is `Call name`, the impl method
   decl; ordering ops wrap it in `__is_less` etc. (resolve.ml:170-198). Compound assignment is
   expanded first (resolve.ml:147-162). Indexing uses `Registry.indexed` (resolve.ml:73, :312).
   A collection literal uses the container entry.
2. **written signature.** Fresh variables for every static param of the decl that is not written.
   Impl params are unified with the receiver's type arguments.
3. **variadic** (desugar.ml:174-196). The decl's last param is `Ty_variadic`, so the trailing args
   are collected into a `Collection_lit`/`Tuple` before they are checked.
4. **args** are checked with `?expected` = param types (§2.4) and unified. `?expected` of the call
   is unified with the ret. A trait-typed param goes through `coerced`.
5. **key** = `Key.of_vars` of the static-param variables.
   - `Error names` → *"static params of 'f' are not settled here: {T = ?}"* (D3; Q2(b) would
     queue the call to the root statement's end instead).
   - Rows: the arg row is zonked and its tail closed before it becomes `Key.Row` (trap T5).
   - Bounds: `admits` (:4627) is checked at the key.
6. **instance** = `w.instance span decl key`. The call is unified with `instance.ty` and the node
   is `Call (Var instance.name, args)`. An associated function drops the receiver
   (`Registry.is_associated`). `instance.name` is added to the current instance's `deps`.

**Trait-object coercion** (`coerced` :1002). For each slot, the method decl of `concrete`'s impl at
the value's key → `Cache.instance` → `Object(data, identity, slots)` with the `Eq` instance for
`identity.equal`. This is a move of resolve.ml:201-262, minus the `declared_types` lookup, since
the slot's type is `instance.ty`. A supertrait upcast stays `__upcast` (resolve.ml:201).

**A method call on a trait object** stays `Dyn_call` with the row from `dynamic_rows` (:68).

### 2.6 Local declarations
A local `fn` statement registers `Decl {scope = Some env}`. Its `Fn` output is a **slot**, filled
when the enclosing instance completes with every instance of that local made so far, in creation
order. Interp defines a block's functions before running it, so position inside the block does not
matter. Capture works because the instance is checked in the defining env, which replaces
`lift_comptime`'s "may read only what it is passed" and `Type_mono.refuse_captures`. A local
`impl` stays an error (*"An impl cannot be generated inside a function body."*, :1991).

### 2.7 Entry (`Metaprocess.program`)
1. `types_of` (:2844), implicit-param rewrite (D4), `collect` (:2818) into `decls`.
2. `Typecheck.Session.start`, then `declare` over all type-level statements (traits, effects, type
   names and bodies, impl *signatures*: :2819-3366 run over `w.types` plus impl headers). Declaring
   an impl is not metaprocessing it, so it is done for every impl.
3. Root statements: `Compile.under_root` applied here, at the program→`stmt` edge. Then
   `Typecheck.walk_root env ctx s` for each, in source order, catching `Located` per statement (D8).
   At each root's end:
   1. Zonk the root and every instance completed under it (`resolve_stmt` :4565) into `processed`.
   2. Run the interim `Resolve`/`Reflect` (steps 4-5).
4. `Session.finish`: deferred-row errors and unhandled effects (:4787-4840).

### 2.8 Prune
Marks from the processed root statements: every `Var n` that names an instance, transitively
through `instance.deps`, plus D6. An instance referenced only from a meta block's processed body,
or made only for `declof`/`typeof`, is never in a root's reference set, so it is not emitted. No
special case is needed.

The output is type-level statements first (written and generated, today's `w.types`), then
instances in completion order (callee before caller, except in cycles), then the roots. That
replaces `slots`/`reachable`/`emit`/`generated` (:3027-3106). Type declarations are emitted whole
under D1.

## 3. Steps
Each step ends with `dune build` passing. "Breaks" lists fixtures likely to change. Run
`dune test --force` and capture the delta before moving on. Never push a fixture that hangs: the
watchdog (test_bootstrap.ml:877, 60s) kills the whole run.

**S1 — Session split and isolation** (typecheck.ml, types.ml). `check_with` becomes `Session.start`
(`Types.reset`, `reset_effects`, tables) + `declare` + `infer` + `finish`. `check` calls them in
order. Add `Typecheck.nested f`. It snapshots every global — the `ctx_*` tables (:162-310),
`unknowns`, `top_row`, `effect_sites`, `deferred_rows`, `dynamic_rows`, `pending_calls`,
`unchecked`, `param_rows`, `Types.declared_params`/`declared_row_params`/`declared_packs`/
`param_names`/`declarations`/`row_params`, the `Resolve` tables and the `Desugar` tables — runs `f`
with them fresh, and restores them. It keeps `Types.counter` monotonic (trap T1). `Metaprocess.run`
(:463) calls `Compile.program` inside `nested`. Breaks: none.

**S2 — C-style `for` in the Parser.** New `bootstrap/lib/lower.ml` takes `fresh`, `bound`,
`looped`, `indexed`, `pulled`, `bound_desugared` (desugar.ml:37-165), retyped over `Ast.stmt`.
parser.ml:1160 builds `Lower.c_for`. `For` leaves `Ast.loops` and every arm in §1's table. Typecheck
:3845-3859 calls `Lower`. Breaks: `tests/meta/syntax/round_trip` and the round-trip runner
(test_bootstrap.ml:969) when the temp name does not scan (trap T8). Also any `code { for (;;) … }`
fixture that prints the quote: `grep -rl 'for (var' tests/meta`.

**S3 — Typecheck over surface syntax; Desugar deleted.** Change every `Ast.desugared_*` in
typecheck.ml to `Ast.expr/stmt` and add the delta arms (§2.1, D7): variadic at the `Call` arm
from a `ctx_variadic_arity` table filled in `hoist`; named handlers collected in `hoist` and resolved
at `Run`; `Attributed` records `Typecheck.decl_attrs`; `Code*` and `__moduleof` errors;
`New_generic`→`New` check. `Compile.program` = `under_root` → `Typecheck.check` → … .
precheck.ml:163 drops `Desugar.program`. Delete desugar.ml and `Diagnostic.Desugar`. Breaks: `.err`
fixtures whose diagnostic stage was Desugar ("Unknown handler", "'code' is only allowed inside a
meta block": `tests/meta/code/errors/outside_meta`, `03_derive/errors/gen_at_runtime`), if the
stage shows. Otherwise green.

**S4 — The fused walk (the big one).** Behind no flag, because two drivers would rot.
- Add `Key`, `Decl`, `instance`, `cache` (§2.2). D4 rewrite in `collect`. The `walk` hook record and
  the `Decl` env binding go in Typecheck (§2.3).
- The call branch is limited to *function calls*, `Static_call`, `Var` and methods (steps 1, 2, 4-6
  of §2.5). Operators, indexing, compound and collection literals still go through Resolve, run per
  root statement at its end. Resolve's `Registry.Call name` is mapped through a new
  `Resolve.instance_of : string -> Types.ty -> string` callback that asks the cache at
  `match_generic decl.ty at`, as `Type_mono.copy_for` did. Resolve's tables are filled
  incrementally (`Resolve.record` per instance, never `reset` mid-session).
- `Metaprocess.program` per §2.7. Meta blocks are still `meta_program` + `run` under
  `Typecheck.nested`, fed with `instance.surface`.
- `Compile.program` no longer runs Typecheck or Type_mono on the walk's output. `Pipeline.whole` =
  Precheck, walk, then `Compile.back`. Type_mono stays in the tree but is called only by `nested`
  meta programs.
- Delete `reach*`, `walk_entry`, `type_of`, `implicit_call`, `runtime_hooks`, `instantiated`,
  `plain`, `survey` users, `standing*`, `Resolve.synthesized` uses.

Breaks, expected:
- **D2**: recursive functions with no written return: `05_order/04_recursion`,
  `05_mutual_recursion`, and every core fixture of that shape. Enumerate with the dump in §4 T9.
- **`var f = helper;`** and `var` let-polymorphism: `tests/types/inference/polymorphism` passes
  (`id` is keyed per type); a lambda bound to a `var` and used at two types fails (lambdas are
  monomorphic).
- **Never terminates**: `tests/types/inference/polymorphic_recursion`,
  `errors/unspecializable_recursion`, `errors/unspecializable_names_the_caller`. They hang, and the
  watchdog kills the run. Move them to Migration before this lands (the doc's Non-termination makes
  them invalid, so they cannot go in `expected_failing`).
- **Walk-order output**: children-first changes the order of meta output wherever a callee's meta was
  printed before its args' (`texpr` visited the callee first, metaprocess.ml:896). Audit
  `tests/meta/05_order/*`, `02_gen/gen_meta`, `02_gen/nested`, `03_derive/*`.
- **"reached whole"**: a trait impl's uncalled methods no longer run their meta. No `05_order`
  fixture has a multi-method trait impl with meta, but grep `tests/` for one. `08_static_invoke`
  and `09_dyn_invoke` are unchanged, since coercion reaches every slot.
- **Messages that go**: `05_order/errors/static_arg_in_meta` ("cannot be instantiated from inside a
  meta block") stays, because `static_call`'s check (:2032) moves into the call branch for meta
  bodies. *"needs its static arguments written"* (:2085) becomes "static params not settled".
- **Partial programs**: `--dump-code` output changes shape for every fixture that pins it.
  `run_prelude_walk` needs `Source.processed`.

**S5 — Expected types.** `?expected` through `infer_expr` (§2.4). Delete `expected_lambda`, the
`check_against` special cases, and `root_argument`'s role in lambda typing (:74, :1856). Collection
literals choose their container by expected type. Fixes the doc's examples: `var xs: Set<int> =
[1, 2]`, `fn make(): Set<int> { return [1, 2]; }`, `takes([1,2])`, `Box { items: [1,2] }`,
`takes_any([1, 2])`, `var g: (int) -> int = helper`. Write these as new fixtures first
(`tests/types/expected/*`, named in `cases`). Breaks: messages where unification used to go
actual-first. Watch `tests/types/errors/*` spans.

**S6 — Resolve folded into the call branch.** Operators, unary, compound, index, collection
containers, `Object` construction, `Run_expr`/`Match_expr` hoisting. A statement arm returns
`hoisted @ [stmt]`, which the walk's `concat_map` already splices; this needs a per-statement
`hoisted` accumulator on `ctx`, moved from resolve.ml:103. `And`/`Or` hoisting (resolve.ml:207)
also moves. The walk now builds `processed_*` nodes. Move `is_trait`/`methods_of` (used by
verify.ml:206,232) to Typecheck. Delete resolve.ml, `bound_calls`, `coercions`, `dp_instance`.
`Compile.back` drops Resolve. Breaks: order of meta output where an operator's impl method holds a
meta block (now reached when the operator node is checked rather than at root end).

**S7 — Type_mono and lifting gone.** Delete type_mono.ml, `lift_comptime`'s function lifting
(§2.6), `comptime_types`'s separate path (a `Type` decl in the cache, D1), and the `Generic`
tolerance in `Types.resolve` for walk mode: an unbound non-collection variable at zonk is *"static
params not settled"*, raised at the root. Verify refuses `Generic`. Breaks: `05_order/15_gen_local`
(a local instance now emitted in place; output should be the same).
`tests/core/functions/forward_calls_stay_pure` should pass trivially, since there is no
generalization in the walk.

**S8 — Prune by reference** (§2.8) and D6. Breaks: anything relying on "plain impls always emitted".
That means `run_prelude_walk`'s "a prelude function a later pass calls survives" (now reached by the
binop call) and printing fixtures under `tests/core/print/*`, `tests/stdlib/text/*` (D6 must hold
them).

**S9 — Meta blocks in walk mode.** `run_meta` (:2230):
1. Lower `gen`/`code` (`lower` :682).
2. Process the lowered body with `walk_body` in a meta env. Its parent is the declaration-level env
   (no runtime vars, so `dynamic_in_meta` still fires through `explain` :1739), and static values are
   bound as locals.
3. Take the processed block plus `instance.deps` closure (instead of `meta_program` :2466) to
   `Compile.back` + Interp.

A call reaching a `Walking` instance keeps *"'f' is still being metaprocessed, so a meta block
cannot call it yet"* (:2483). Delete `Typecheck.nested`, `instance.surface`'s use by meta, and
`meta_program`. Breaks: messages of meta blocks that failed to check (they used to fail in the
nested check with spans from the copy; now they fail in place). Speed improves, since nothing is
rechecked per block.

**S10 — Cleanup.** Delete `Ast.typed_*`/`resolved_*` aliases, the surface `texpr` hooks no longer
used, and the stale `internal-docs` claims. Docs are not this plan's to rewrite. List the stale
claims for the user: Architecture.md Desugar/Type Monomorphize/Resolve sections, Metaprocessing.md
"Methods, impls and trait objects", Type System.md "Checked twice". Comments must not narrate the
migration (CLAUDE.md code style).

## 4. Risks and traps
- **T1 Variable ids collide across sessions.** `Types.reset` sets `counter := 0` (types.ml:140).
  `declared_params`, `is_unknown`, `param_names` and the row tables are keyed by id. A meta block
  checked mid-walk with a reset counter mints ids equal to live ones. `nested` must keep the
  counter monotonic and snapshot the id-keyed tables. After S9 there is one session and no resets.
- **T2 `scoped_declarations` (:315) restores snapshots at block exit.** In walk mode a block's
  checking can trigger an instance or a meta block that registers *top-level* types or impls, and
  the restore wipes them. Local types are already renamed per owner (`lift_comptime` :2900), so walk
  mode does not need the scoping: skip it.
- **T3 Local types inside an instance.** `fn f<T>() { type Temp { x: T } }` renames to `f#Temp`
  once. Two instances would then declare one name at two field types in `Types.declarations`
  (types.ml:1450, keyed by name). Rename by instance name.
- **T4 Zonk timing.** An instance body can share variables with a top-level `var` still open
  (`var xs = []` then a function reading `xs`). Zonking at the instance's own end turns them into
  `Generic`. Zonk at the end of the *root statement* that reached it. A variable still open at that
  point is "not settled".
- **T5 Rows as key args.** A lambda's row has an open tail. Closing it at key time must *unify* the
  tail with `REmpty`, so the instance and the call agree. A row closed only in the key leaves the
  caller's row to grow later, and CPS then gives the callee different evidence. This is the
  `forward_calls_stay_pure` / issue #116 failure in another form (Type System.md "Polymorphism").
- **T6 `__root<T, X, E>`** (stdlib/prelude.cx:54). `X` occurs only in `Throw<X>` in `main`'s row. A
  statement that never throws leaves `X` open, which breaks every program under a strict reading.
  See Q1. `E` makes one `__root` instance per distinct statement row, which is expected and fine.
- **T7 Instance naming.** A `{}` instance must keep its written name (D5): `typeof`, runtime
  errors, the `Display` lookup (builtins.ml:242 builds `name#Trait#method`) and `--dump-code` all
  read it. A generic Display impl's instances will not be found by that lookup at all (D6, Stdlib
  plan).
- **T8 Parser temporaries.** `Lower.looped` with `continue` needs a `first` flag (desugar.ml:75).
  Its name must scan for `run_round_trip` (print → reparse). It must also be stable: the second
  parse sees a `while`, so it makes no new temp. Use a spelling the scanner accepts but a program
  cannot declare, or check how `Source` prints `Ast.generated`.
- **T9 Unannotated recursion (D2) is the biggest migration cost.** Size it before S4 with a probe:
  in the S4 branch, make the Walking-signature error a hard failure and run
  `dune test 2>&1 | grep "still being metaprocessed and its signature"`. Hand the list to
  Migration.
- **T10 `pending_calls`/`unchecked`/`discharge_pending`** (:605-634) exist because a callee could be
  unchecked when called. In walk mode the only unchecked callee is `Walking`, and it is handled by
  its written signature. Keep them for whole mode only; mixing them into walk mode double-reports.
- **T11 `has_generic`/`match_generic` must agree** (Type System.md). The S4 interim
  `Resolve.instance_of` uses `match_generic` like `copy_for`. It goes away in S6. Do not build on it.
- **T12 GADT refinement** (`Types.solve`, typecheck.ml:4148 `infer_match`) assumes generic
  scrutinees. At a concrete key a refinement is a plain equation that holds or fails, and an arm
  that cannot match a concrete key is unreachable. `tests/types/gadt/errors/leaked_constraint`
  needs a look, since it reports two errors.
- **T13a `check_static` (metaprocess.ml:1542 `checks`) runs `Compile.program`** on a probe to
  check a static value argument against its declared type: one more whole check inside the walk.
  It goes under `nested` in S1, and in S4 it becomes `unify` of the argument's checked type.
- **T13 Precheck and the walk share module globals.** Precheck finishes before `Session.start`, and
  must keep doing so. Never call `Precheck.program` from inside the walk.
- **T14 Implicit params and `as_function` UFCS.** `x.f()` falls back to a free `f(x)` (Type
  System.md "Settled"). With D4, `f`'s first param is a static param, so the receiver's type is
  its key: correct, but the fallback now instantiates rather than generalizes. Also: library code
  that avoids common method names exists for a reason (memory: library method name capture).
- **T15 `wake` before lookup.** A deferred module's meta runs on the first name asked. The `decl`
  hook must call `wake` (:2434) before `Hashtbl.find decls`, including for method decls reached
  through a receiver (mangled names carry the module prefix).
- **T16 `For_in` builds checked code mid-check** (:3857). Under S5 its synthesized `len`/`[]`/`next`
  calls go through the call branch and so reach instances. They are real references, which keeps
  Prune right.

## 5. Interfaces this slice exposes

**Reflection / Splice**
- `Typecheck.walk.splice_expr ~expected stmt`: a `meta` in expression position, with the expected
  type of the slot. Reflection implements it. This slice calls it from the `Meta`-as-expr arm.
- `Metaprocess.declof : world -> span -> Decl.t -> Key.t -> instance`: returns the instance with
  `processed` and `surface`. The instance is not added to any `deps`, so Prune drops it unless the
  program references it.
- `Typecheck.type_now : checked_expr -> Types.ty` (zonk, or fail "not settled yet") for `typeof`.
- `register` for generated declarations, with `Typecheck.declare_incremental` already done.
- Key show/print (`Key.show`) and `Types.to_type_expr`, for writing a key back into syntax.
- Precondition they rely on: `code`/`gen` are lowered before a block is processed (`lower`
  :682), so quoted syntax is never checked.

**Effects**
- `Key.Handler of label * ty` exists and takes part in `Key.show` and the cache key. The call
  branch passes the enclosing run's bindings (an `effects : (string * Types.ty) list` on `ctx`,
  empty until Effects fills it) when the callee's row mentions a bound label.
- A meta block calling `effect_transform<E, H>(code {…})` is an ordinary meta block plus
  `declof` and `gen` under a new name (`register`). No special entry point is needed from this
  slice.
- `Decl.Type`-like keyed *traits* (`trait EffectHandler<E, R> { meta … }`) need a `Trait` decl
  kind instantiated per key, as D1 does for types with meta members. Effects adds the kind. The
  cache takes it unchanged.
- CPS stays in `Compile.back` until `effect_transform` replaces it. The processed tree keeps rows on
  every `Fn` annotation (T5).

**Migration**
- The fixture lists from S4/S7/S8 (T9 probe output), the three non-terminating fixtures, and
  `run_prelude_walk`'s expectations.
- New fixtures this slice writes first: the doc's Expected Types, Recursion and generic-as-value
  examples, under `tests/meta/process/` and `tests/types/expected/`, each named in
  `test_bootstrap.ml`'s lists (CLAUDE.md: an unnamed fixture is a failure of its own).

## 6. Questions (each changes the base implementation)

**Q1. A static param nothing constrains.** `__root<T, X, E>`: in `print(1)`, `X` appears only in
`Throw<X>` in a row the lambda does not perform, so the call cannot settle it.
- (a) Error, as the doc reads. That breaks every program until `__root` changes. One way to change
  it: `Throw` gets a fixed payload type, or `__root` takes `X` from an effect-row binding.
- (b) Default an unconstrained param to `unit` when it occurs only in an effect label's arguments,
  and raise an error anywhere else.

Recommend (b). It is local to `Key.of_vars`, and `var f = helper;` stays an error.

**Q2. Where a key must be settled.**
```cronyx
var xs = [];          // Array<?a>
xs.push(1);           // push's T is settled by this call's own argument: fine under both
fn first(ys) { return ys[0]; }
var y = first(xs2);   // xs2 : Array<?b>, ?b fixed by a later statement
```
- (a) Strict: at the call, after its args.
- (b) At the call when possible. Otherwise the call is typed from the written signature and queued,
  then resolved at the end of the enclosing root statement, and still-open is an error.

(b) needs the queue plus the written-signature typing, about 60 lines, and accepts code in which
a later sibling expression settles a variable. Recommend (a): it is what the doc says, and it
keeps the call branch one-shot. The plan is written for (a); (b) adds the queue at §2.5 step 5 and §2.7 step 3.

**Q3. Plain generic types.** D1 keeps `type Box<T>` parametric: one `Types.declarations` entry,
`typeof(Box<int>).name` unchanged, and only methods monomorphized. The alternative is a type
instance per key (`Box$int` as its own record), which is the literal reading of "a declaration is
only ever metaprocessed at a key". It would rename record values at run time (the D6 lookup,
`Value.Record (Some name, …)`) and every reflection fixture. Recommend D1.
