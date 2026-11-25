# Plan 03 — Effects and `effect_transform`

Scope: `internal-docs/CPS Migration.md` Working Examples, `# EffectHandler`, and the fixed meaning
of `run`/`handle`/`with`. Plans 01 (Metaprocess core) and 02 (Reflection/Splice) are assumed. Their
interfaces are cited as `01:Key.Handler` and `02:I5`–`I9`. `cps.ml` is replaced. The interpreter keeps
two built-ins: `discontinue` (with its signal) and general tail calls.

Headline findings. §12 has the questions.
1. **Every program runs through a function value.** Every top-level statement reaches its handlers
   as the lambda `main` passed to `__root` (stdlib/prelude.cx:54). A run whose body calls a
   *parameter* cannot be transformed through `declof`, and nothing else says how. The same shape
   appears in `attempt`, `iterator`, `block_on`, `spawn` and `Task.all` (Q1). Plan 01's T6/Q1 hit
   the same function from the typing side.
2. **Composition only works with honest continuation rows.** When runs nest and are transformed
   inside out, each output must type-check (Truth 1), so `resume` has to be typed
   `(A) -> <ρ> R`, where ρ is what the run passes outward. Today it is pure (Continuations and
   Tasks.md). With ρ in the type, the rest of an arm splits by construction (#123 becomes
   impossible). The cost is `abort_after_resumption`'s pure `List<() -> unit>` (Q2).
3. **`return` crossing a run needs no new primitive.** A flag, plus the discontinue signal used as
   a placeholder `R`, plus a rewrite of the arms on the path covers it (§4.7). It does not need
   Return_value-through-`Frame`.

---

## 1. Code map of today's implementation, and its fate

| Where | What | Fate |
|---|---|---|
| token.ml:55-83, scanner.ml:49-79 | keywords `ctl final effect handle handler resume discontinue run with` | `effect handler ctl final resume discontinue` are deleted. `run handle with` stay. `discontinue` becomes a prelude function. |
| parser.ml:853-858 | `effect`/`handler` declarations | Deleted. `effect X {}` becomes `trait X {}`, and `handler n : E {}` becomes `type N {} impl … for N`. |
| parser.ml:1197-1243 `op_kind`, `effect_decl` | `fn`/`ctl`/`final ctl` op kinds | Deleted. A trait method's `@ctl` comes in through `attributes` (already on `MethodSig.attrs`). |
| parser.ml:1506-1549 `handler_decl`, `handler`, `handler_clauses` | arms with untyped params, `handle E {}`, `with name` | Rewritten as `handle<TypeExpr> { method defs }` and `with TypeExpr` (§3.3). |
| parser.ml:1551-1618 `run_stmt`, `valued_block`, `run_expr` (+ `return (x) {}` clause :1597-1616) | `run` as an expression or a statement | Kept, plus `run<R>`. The return clause is kept (D3). |
| parser.ml:1085-1097, 1620-1623 | `resume e;` and `discontinue;` statements | Deleted. Both become calls: `k(e)` and `discontinue(k)`. |
| ast.ml:120-123 `op_kind`, :139-165 `op_decl`/`handler`/`arm`, :427-438 `handler_clause`/`handler_defs`/`effects` | the effect fragment | `op_kind`/`op_decl`/`arm`/`Effect_decl`/`Handler_decl`/`Resume`/`Discontinue` are deleted. `Run_expr` holds `handler_clause = Inline of type_expr * method_def list \| Named of type_expr`. |
| ast.ml:485-509 `ret_clause`, `run_expr`, `aborts` (`Scope`/`Abort`/`On_unwind`) | CPS-only nodes | `aborts` is deleted. `run_expr` stays surface-only: the walk lowers it (§3.4). |
| ast.ml:700-715 `Cont`, `Frame`; :781-782 `discontinue_name`/`discontinued_name` | continuation closures that re-enter scopes or let a `return` through | Deleted. `cps_stmt` becomes the processed statement. Both names go to `Builtins`. |
| stdlib/compiler/Ast.cx:224-226,241-243,307-369 | `StmtKind.Run/Resume/Discontinue`, `DeclKind.Effect/Handler`, `EffectDecl/OpKind/OpDecl/Handler/Arm/HandlerClause` | `ExprKind.Run(ValuedBlock, List<HandlerClause>, Option<ReturnClause>)` stays, with `HandlerClause { Inline(TypeExpr, List<MethodDef>), Named(TypeExpr) }`. The rest is deleted. syntax.ml:175-176,251-253,317,624,704-706,778 and Printer.cx follow. |
| desugar.ml:253-303 | named handlers inlined by name (`declared`, `clause`) | Deleted, with Desugar itself (01:S3). A named handler is a type. |
| typecheck.ml:125-143 `ctx.resume_type/in_final_arm`, `ctx_effects`, `ctx_op_owner` (one op namespace) | effect tables | `ctx_effects` is replaced by "a trait used in a row". `ctx_op_owner` becomes a trait-method lookup for receiverless calls (T3). `resume_type`/`in_final_arm` are deleted. |
| typecheck.ml:4010-4084 `Effect_decl` | binds each op as a global scheme. `final` quantifies the result (:4049-4056) | Replaced: a receiverless call to a trait method whose trait is in scope gives the row `{Trait<args> \| ρ}` (§3.1). `final`'s quantification becomes the op's own static param (§3.2). |
| typecheck.ml:4085-4126 `Run`/`Resume`/`Discontinue` | statement typing | `Run` is typed by `check_run` over a `run_expr` (kept, see below). The other two are deleted. |
| typecheck.ml:4353-4490 `check_run`, `infer_handler`, arm-vs-op kind (:4441 `handler_widens`), `resumes` (:1267) | discharge a label, type arms, answer type | `check_run` stays as the run's *fixed typing rule*, which Precheck needs (T11). Arms are checked as methods of an impl of `EffectHandler<E, R>`. `handler_widens` and `resumes` are deleted. |
| typecheck.ml:4790-4810 | a deferred statement may not perform an effect with a `final ctl` op | Kept, keyed on "a never-resuming op" (§3.2). |
| typecheck.ml:1194,1239-1269,1323,1401-1405 | assigned-name and capture walks over `Run`/arms | Follow the new node: arms become method bodies. |
| resolve.ml:377-428 (`Run_expr` hoist + temp), :556-577 `answering` (an arm's `return` answers the run), :663, :690-705 | lowering | Deleted. An arm is a method returning R, so its `return v` answers the run with no rewrite. Resolve is folded into the checker anyway (01:S6). |
| type_mono.ml:13 `in_arm`, :80,99,110,307,317,389,551-566,658,755 | arm-owned type variables | Deleted with Type_mono (01:S7). |
| metaprocess.ml:17-18, 399-413, 881-890, 966 | effect/handler decls, arm shadowing, `Run_expr` walk | `Run_expr` becomes "lower to meta + gen" (§3.4). The rest is deleted. |
| cps.ml (1498 lines) | `collect` :1385 (owner/delimited per *effect*), `cps_stmts` :648-962, `run` :1122, evidence-only `stmt` :1206 (`Fn` wrapper with stash/crossed :1240-1296), `direct_arms` :1316, `sequence_body` :1346, `fields_of` :1488 (used by verify.ml:42) | **Deleted.** `cps_stmts`' case analysis is ported to Cronyx (§4). The evidence translation is replaced by keyed handler binding (01:Key.Handler, §3.5). Verify reads `Types.named_fields` directly. |
| interp.ml:10-17 `Aborted`, `active_scopes`; :19-37 tail flags; :245-262 `under`/`carry_on`; :273-336 `closure ~is_continuation ~returns`; :358-380 `bounce`; :410-452 `exec_last`/`leaving`/`discontinuing`; :465-476 `Scope`/`Abort`/`On_unwind`; :509-513 `Cont`/`Frame`; :552-556 | scope re-entry, aborts, tail calls only for Cont/Frame | Scopes, aborts, `Cont`/`Frame` and `leaving` are deleted. Tail calls are generalized to every closure (§6). The discontinue builtins move to builtins.ml. |
| compile.ml:96-98 | `Cps.program` stage | Deleted. `Compile.back` = Verify → Interp. |
| stdlib: Console.cx:52,74, Error.cx:44,142, Args, Assert:22, Logger:46, Time:213, Yield:20, Task.cx:29 (+ runs :172-212, :297-320), Env, File.cx:58,71, Process:38,178, Random, Net:24, prelude.cx:54-100 | 17 effects, about 25 runs | Rewritten in step S9. |

## 2. The model in one page

- **An effect is a trait in a row.** `trait Ask { @ctl fn ask(): int; }`. A receiverless call
  `ask()` resolves to `Ask.ask` when `Ask` is in scope, and contributes `Ask` to the caller's row.
- **Binding is the core's job; splitting is the transform's.** A `run` extends the key with
  `{Ask = H}` for everything its body reaches (01:Key.Handler, `ctx.effects`). In an instance at
  that key, a call to an **unmarked** op resolves in the call branch to the handler's method
  instance, `H.log(hv, msg)`. That is evidence passing with a static target, and no rewrite. A call to
  a **`@ctl`** op stays an op call in processed code, and `effect_transform` splits there.
- **A handler value.** Its type is static (part of the key). Its value is a record of what the
  `handle` block captures, built at the run site and passed as the first parameter `hv` of each
  method and of each instance under the key. Interim representation: a record of closures, which
  captures by reference for free (§3.5). With no captures, the value is `()` and the parameter
  disappears.
- **After the transform** only lambdas, calls, local `fn`s and `if` remain, plus B1/B2 (§6).

## 3. Surface and typing

### 3.1 Effects and rows
- A row label is a trait name with its args (`Yield<int>`). `Types.row` is unchanged: labels are
  strings with args (types.ml:75). Row errors keep their text except where they say "effect"
  for a non-trait (`unknown_effect` → "'nope' is not a trait").
- Op lookup: a receiverless `f(args)` that resolves to no value looks for a trait method `f` among
  the traits in scope that are effects. An effect is a trait none of whose methods takes `self`
  (D4). Two traits in scope with the same method name is "ambiguous operation 'f': A.f or B.f",
  which replaces `duplicate_operation`. `A.f()` qualifies the call
  (`qualified_op/`, `named_import/`, `handled_in_import/` become `Signal.signal()` or a plain
  import).
- `@ctl` is an inert attribute (ast.ml:125-137 already carries it on `MethodSig.attrs`). Only
  `EffectHandler`'s meta block and the transform read it.

### 3.2 `final ctl` → `@ctl fn throw<T>(err: X): T`
Kept: a fresh result type per call site. An op's own static param T that does not occur in its
params is instantiated per call, which is the existing mechanism (op type params, ast.ml:144;
trait-method static params). Kept: soundness. `EffectHandler` gives `throw<T>(err: X, k: (T) -> R): R`,
and the handler can never build a `T`, so it can never call `k` (parametricity). Lost: the
explicit "cannot resume" diagnostic (`final/errors/resumes`). It becomes an ordinary type error at
`k(…)` ("expected T, got int"), and the fixture's `.err` changes. Lost by default: the cheap unwind.
A `throw` now splits its caller, which costs at run time and at compile time (§10). "A deferred
statement cannot fail" (typecheck.ml:4790) keys on "an op with its own static param occurring only
in its result". `discontinue_outside_ctl`'s first error has no equivalent and goes away.
`Error.cx:44`, `Assert.cx:22` and `Process.cx:38` (`exit`) move to this form.

### 3.3 `run`, `handle`, `with`
```
run<R>? { valued block } (handle<TypeExpr> { method defs } | with TypeExpr)+ (return (x) { … })?
```
- **R** is written, or comes from the expected type, or from the body's value (`unit` for a statement
  run). Whatever `return` arms and `k` produce unifies with it.
- **`handle<E>`** declares an anonymous type `__Handler#n` (an unwritable name) and
  `impl EffectHandler<E, R> for __Handler#n { defs }`. The trait instance comes from 02:I5. A method
  param with no written type takes its type from the trait's signature and never becomes an
  implicit static param (trap T5). The continuation is the last param, under any name. A
  `@ctl` op's method has the shape `(args…, k: (A) -> <ρ> R) -> R`, with ρ EffectHandler's implicit
  row param (§7, Q2), and an unmarked one has
  the op's own signature. An effect with no `@ctl` op: the impl is `impl E for __Handler#n` (its own
  EffectHandler, per the doc).
- **`with H`** binds every effect E for which `impl EffectHandler<E, _> for H` or `impl E for H`
  exists and which the body's row (from Precheck) holds. A named handler for a `@ctl` effect is
  `type Picker<R> {}` with `impl<R> EffectHandler<Effect, R> for Picker<R>` (02:Q2 open slot).
  `with Picker` instantiates R from the run.
- **Errors**, all in `check_run`: two clauses binding one effect ("'Ask' is handled twice in this
  run"); `with H` binding nothing the body performs ("'H' handles nothing this run performs"); a
  missing method (today's `non_exhaustive`, now the impl's "missing method"); an unknown method
  (`no_such_operation`, now the impl's "has no method").
- **Answer of an arm.** A `@ctl` method's `return v` answers the run, because the method returns R.
  Falling off the end of a method returning non-unit R is the ordinary missing-return error.
  Today's "aborts with unit" (typecheck.ml:4469-4475) is the special case R = unit. `return_clause`
  wraps the body's value: R is the clause's type.
- **Arms checked outside their run.** The impl methods are declarations outside the body, so an
  op they perform reaches the enclosing run. That is `arm_reaches_outer`, and it holds by
  construction.

### 3.4 Lowering `run` (the fixed meaning)
At the walk, for a `Run_expr` node (statement or expression):
```cronyx
{ var __hv#1 = __Handler#1 { /* captured locals by reference */ };
  meta { gen effect_transform<R, __Handler#1, H2>(code { body }, code(__hv#1), code(H2.value)); } }
```
This extends the doc's `effect_transform<E, H>` to a pack, so that one run binds several handlers
with the outside-the-run arm semantics (D1). E is read off each handler's impls. The handler value
of a named type with no fields is `()`. The return clause is passed as a fourth argument
`Option<ReturnClause>`. As an expression, the meta block must splice exactly one `Expr` (02:I6).
The transform returns an immediately-called lambda `(() => { … })()` when it needs statements (D2).

### 3.5 Handler values and capture
`__Handler#n`'s fields are the locals the block reads, captured by reference (Ast param closure
analysis, typecheck.ml:1323). **Interim:** the value is the record
`{ ask: (k) => {…}, log: (m) => {…} }` built at the run site, and each method instance under the key
is `hv.method(args)`. That reuses closure capture, and is how ~20 fixtures and Task.cx:183
(`cancelled`, `failure`) keep working. **Target:** a named-field record, with methods as
declarations taking `hv`. That waits on 01 making impl methods instances. Either way, the transform
receives `code(__hv#n)` and threads it as a parameter.

## 4. `effect_transform` (library: `stdlib/effects/Transform.cx`)

### 4.1 Inputs, outputs, state
```cronyx
import { Expr, ExprKind, Stmt, StmtKind, Param, Signature, TypeExpr, Name } from "std/compiler/Ast";

type Bound { effect: TypeExpr, handler: TypeExpr, value: Expr, ctl: List<Name> }

type Cx {
    bound: List<Bound>,         // this run's bindings, innermost run's only
    answer: TypeExpr,           // R
    ret: Option<Name>,          // continuation a `return` calls; None at the run body's top
    next: Name,                 // what the next statement runs under
    breaking: Option<Name>, continuing: Option<Name>,
    cleanups: List<Cleanup>,    // defers in scope: flag + statement, re-armed per continuation
    leave: Option<Leave>        // flag + slot for a `return` that crosses this run (4.7)
}

fn effect_transform<R, ...H>(body: List<Stmt>, values: List<Expr>, clause: Option<ReturnClause>): Expr {
    var bound = bindings<R, H...>(values);                  // declof(H) impls → effect + @ctl ops
    var p = processed(body, bound);                         // R1: typed, meta-free, at key ∪ bound
    if (!splits_any(p, bound)) { return as_expr(p); }       // only unmarked ops: already bound
    var cx = Cx.top(bound, typeof_answer<R>(), clause);
    var end = fresh("end");                                 // the run's terminal continuation
    return block_expr([ terminal(cx, end, clause) ] + stmts(cx.with_next(end), p, 0));
}
```
`processed` (R1) processes the quoted body at the meta block's scope under the extended key. Inner
runs are lowered and transformed during that call, which gives inside-out order for free. Unmarked
ops come back already bound. `@ctl` ops of **this** run's effects come back as
`OpCall(effect, op, args)`. Ops of unclaimed effects also stay op calls, and the enclosing run's
transform splits them later.

### 4.2 Finding a split
A call splits when its callee's row (R2) holds a label in `cx.bound` with a `@ctl` op that the callee
can reach. For an op call that is immediate. For a named callee it is a property of the instance's
row. That makes the pass selective by operation, not by effect, as the doc says (cps.ml:1 split by
effect).
```cronyx
fn splits(cx: Cx, e: Expr): bool {
    match e.kind {
        ExprKind.Call(f, args) => { return performs_ctl(cx, callee_row(f)) || any_splits(cx, args) || splits(cx, f); }
        ExprKind.And(a, b) | ExprKind.Or(a, b) => { return splits(cx, a) || splits(cx, b); }
        ExprKind.Lambda(_, _, _) => { return false; }       // a value: rewritten in place (4.6), never a split here
        _ => { return any_child(e, (c) => splits(cx, c)); }
    }
}
fn performs_ctl(cx: Cx, row: List<Applied>): bool {
    for (b in cx.bound) { for (l in row) { if (same_label(l, b.effect) && b.ctl.len() > 0) { return true; } } }
    return false;
}
```
`b.ctl` is the effect's `@ctl` op names, read from `declof(E)` (`takes_control`, as in the doc).
"A function that calls `log` and never `choose`" is skipped: at an op-call site the test is per op,
and for a named callee the row says which effects, not which ops. Default D5: a callee splits
if its row holds the effect and any of the effect's ops is `@ctl`. Finer reach would need
per-op rows.

### 4.3 Statements: a port of `cps_stmts` (cps.ml:648-962)
```cronyx
fn stmts(cx: Cx, ss: List<Stmt>, i: int): List<Stmt> {
    if (i == ss.len()) { return [tail_call(cx.next, unit_lit())]; }
    var s = ss[i];
    if (!splits_stmt(cx, s) && !exits_across(cx, s)) { return [plain(cx, s)] + stmts(cx, ss, i + 1); }
    var rest = (c: Cx) => stmts(c, ss, i + 1);
    match s.kind {
        StmtKind.Expression(e)         => { return anf(cx, e, (v) => rest(cx)); }
        StmtKind.Let(x, ty, Option.Some(e)) => { return anf(cx, e, (v) => [let_(x, ty, v)] + rest(cx)); }
        StmtKind.LetTuple(xs, e)       => { return anf(cx, e, (v) => [let_tuple(xs, v)] + rest(cx)); }
        StmtKind.Return(v)             => { return ret(cx, v); }                       // 4.7
        StmtKind.Break                 => { return [tail_call(cx.breaking.unwrap(), unit_lit())]; }
        StmtKind.Continue              => { return [tail_call(cx.continuing.unwrap(), unit_lit())]; }
        StmtKind.If(c, t, e)           => { return joined(cx, rest, (j) => cond(cx, c, (b) => [if_(b, block(stmts(cx.with_next(j), [t], 0)), else_or_call(cx, e, j))])); }
        StmtKind.Match(x, arms)        => { return joined(cx, rest, (j) => anf(cx, x, (v) => [match_(v, map_arms(arms, (body) => stmts(cx.with_next(j), body, 0)))])); }
        StmtKind.Block(body)           => { return joined(cx, rest, (j) => stmts(cx.with_next(j), body, 0)); }
        StmtKind.While(c, body)        => { return loop(cx, c, body, rest); }
        StmtKind.Defer(d)              => { return deferred(cx, d, rest); }            // 4.8
        _ => { return [plain(cx, s)] + rest(cx); }
    }
}

// `rest` becomes a local function, and each branch ends by calling it.
fn joined(cx: Cx, rest: (Cx) -> List<Stmt>, branch: (Name) -> List<Stmt>): List<Stmt> {
    var j = fresh("join");
    return [local_fn(j, [param(fresh("x"), unit_ty())], cx.answer, continuation_body(cx, rest(cx)))] + branch(j);
}

// A loop holding a split is recursion. The condition is evaluated inside `again`, once per iteration.
fn loop(cx: Cx, c: Expr, body: Stmt, rest: (Cx) -> List<Stmt>): List<Stmt> {
    var again = fresh("loop"); var after = fresh("after");
    var inner = cx.with_next(again).with_breaking(after).with_continuing(again);
    return [ local_fn(after, [param(fresh("x"), unit_ty())], cx.answer, continuation_body(cx, rest(cx))),
             local_fn(again, [param(fresh("x"), unit_ty())], cx.answer, continuation_body(cx,
                 cond(cx, c, (b) => [if_(b, block(stmts(inner, [body], 0)), block([tail_call(after, unit_lit())]))]))),
             tail_call(again, unit_lit()) ];
}
```
- `plain(cx, s)` copies a statement that holds no split. A lambda inside it is still rewritten
  (4.6), and a `return` in it is still translated: `ret` (cps.ml:240 "a statement holding a return
  is converted whether or not anything in it suspends") is the `exits_across` test.
- `for`/`for-in` are lowered to `while` by the parser/checker before the transform sees them
  (01:S2). `for (x in xs)` over an indexed sequence is `while` plus an index (typecheck lowering).
- `tail_call(f, v)` is `return f(v);`, which the interpreter guarantees in tail position (§6).
- `continuation_body(cx, ss)` prepends the discontinue test and re-arms the cleanups (4.8).

### 4.4 Expressions: `anf`, which keeps the order and splits at the first `@ctl` call
```cronyx
// The statements that evaluate `e` and pass its value to `k`, splitting at each call that splits.
fn anf(cx: Cx, e: Expr, k: (Expr) -> List<Stmt>): List<Stmt> {
    if (!splits(cx, e)) { return k(rewrite_values(cx, e)); }
    match e.kind {
        ExprKind.Call(f, args) => {
            return anf(cx, f, (fv) => anf_list(cx, args, (avs) =>
                if_split(cx, f, fv, avs, k)));          // a call that splits becomes split(...), anything else a temp
        }
        ExprKind.And(a, b) => { return logic(cx, a, b, true, k); }
        ExprKind.Or(a, b)  => { return logic(cx, a, b, false, k); }
        ExprKind.FieldAssign(t, f, v) => { return anf(cx, t, (tv) => anf(cx, v, (vv) => k(field_assign(tv, f, vv)))); }
        ExprKind.IndexAssign(t, i, v) => { return anf(cx, t, (tv) => anf(cx, i, (iv) => anf(cx, v, (vv) => k(index_assign(tv, iv, vv))))); }
        ExprKind.MethodCall(r, m, args) => { return anf(cx, r, (rv) => anf_list(cx, args, (avs) => if_split_method(cx, rv, m, avs, k))); }
        _ => { return anf_children(cx, e, k); }        // binary, unary, tuple, record, New, NewVariant, Index, …: left to right
    }
}

// `a && b` with a split in `b`: `b` is reached on one branch only, so the operator becomes a branch.
fn logic(cx: Cx, a: Expr, b: Expr, is_and: bool, k: (Expr) -> List<Stmt>): List<Stmt> {
    var j = fresh("join"); var v = fresh("v");
    var evaluated = anf(cx, b, (bv) => [tail_call(j, bv)]);
    var settled = [tail_call(j, bool_lit(!is_and))];
    return [local_fn(j, [param(v, bool_ty())], cx.answer, continuation_body(cx, k(var_(v))))]
         + anf(cx, a, (av) => [if_(av, block(if is_and { evaluated } else { settled }),
                                      block(if is_and { settled } else { evaluated }))]);
}

// The split itself: the rest is the continuation, and the call answers the run.
fn split(cx: Cx, target: Target, args: List<Expr>, k: (Expr) -> List<Stmt>): List<Stmt> {
    var x = fresh("x");
    var kont = lambda([param(x, target.result)], cx.answer, continuation_body(cx, k(var_(x))));
    return [ return_(call(target.callee, target.prefix + args + [kont])) ];
}
```
`Target` is resolved from the callee:
- **An op of a bound effect.** `callee = H.op` (the handler's method instance), `prefix = [hv]`.
- **A named function or method instance** whose row splits. `callee = transformed(cx, inst)`, and
  `prefix` is the handler values that instance takes (4.5).
- **A local value** whose type was rewritten (4.6). `callee` = the value, `prefix = []`.
- **A value from outside the region.** Q1.
- **A trait-object method** (`Dyn_call`) whose row splits. Rejected for now with "a trait object
  whose method performs '@ctl' op 'ask' cannot be called under this run yet". This puts
  `methods/suspending_receiver` at risk (D6).

Evaluation order is left to right, callee first, receiver before args, target before index before
value (interp.ml:336 `eval_all` is explicitly left to right; trap T9). That covers
`suspend_in_field_assign`, `suspend_in_variant`, `suspend_in_record`,
`suspend_in_tuple_destructure`, `suspend_in_resume` (`k(get())`: the arm is transformed too, 4.6) and
`suspend_in_condition`. A `while` condition is evaluated inside `again` (`suspend_in_while_condition`).

### 4.5 Callees: `declof`, gen under a new name, cache
```cronyx
// The instance `f` at this run's key, with every split point in its body handed a continuation.
fn transformed(cx: Cx, f: Name): Name {
    var key = cache_key(f, cx.bound);                    // (instance name, handler types)
    match cache.get(key) { Option.Some(n) => { return n; } _ => {} }
    var d = declof_instance(f);                          // R3: processed FnDecl, signature fully written
    var name = fresh_global(f, cx.bound);                // R4: unwritable, unique
    cache.set(key, name);                                // before the body: recursion reaches it
    var fn_cx = Cx.function(cx.bound, d.signature.ret, fresh("k"));
    var params = handler_params(cx.bound) + d.params + [param(fn_cx.ret_name(), arrow([ret_of(d)], answer_param()))];
    gen_decl(fn_decl(name, [answer_static_param()], params, answer_param(),
                     continuation_body(fn_cx, stmts(fn_cx.with_next(fn_cx.ret_name()), d.body, 0))));
    return name;
}
```
- **Generic over the answer.** The new function is generic over `__R`. The continuation is
  `(T) -> <ρ> __R` and the return is `__R`. One transform per (decl, handler types) is then shared
  by every run whose R differs, and 01's cache monomorphizes `__R` cheaply. This is the main
  compile-time lever (§10).
- **The cache lives in the transform's meta state, per program.** It needs a meta-global
  memo table that persists across `effect_transform` calls (R6), or the core's decl cache keyed by
  `(f, {E = H})` plus a "transformed" tag (M3). This plan uses M3: `declof(f<{Ask = H}>)` is the
  instance, and the generated `f$cps` is registered as a sibling instance the transform can look up
  by name.
- Mutual recursion terminates because the name is reserved before the body (4.5 line 5). That
  matches cps.ml's reliance on `info.functions` (cps.ml:1394).
- **A method instance** (`o.audit()`, `methods/methods`) is the same path, through the impl method's
  instance name (`Ast.impl_method_name`).

### 4.6 Function values and arms inside the region
- **A lambda in the region** whose row splits, such as `var task = () => { trial(); }`
  (`fn_values/multishot_closure`), is rewritten in place: `(params…, k) => body'`. **Every
  function type written in the region** whose row holds a bound `@ctl` label is rewritten the same
  way, which keeps `tasks: List<() -> <E> int>` consistent (`fn_values/in_list`, `in_tuple`,
  `through_index`). A call through such a value is a split with `prefix = []`.
- **Parameters of a transformed function** have function types too, and get the same rewrite.
  The callers inside the region pass rewritten lambdas (`final/in_loop`'s `apply`).
- **Arms are transformed for the outer runs, not their own.** An arm's body is outside its run but
  may be inside an outer run's region: inline handler methods are code in the enclosing body. For a
  named handler type, its methods come through `declof` and are gen'd as `H$cps`. With Q2's honest
  rows, `k: (A) -> <ρ> R` performs whatever the outer run binds, so a `k(x)` in the arm splits for
  the outer run, and the rest of the arm becomes the outer continuation. That is `resume_through_run`,
  `inner_run_suspends_outward`, `return_past_outer_ctl_run`, and #123 / `iterator_suspends`.
- **Discontinue insertion.** An arm whose body never mentions its continuation parameter gets
  `discontinue(k)` before each exit (`return`, and falling off the end). The test is syntactic over
  the method's declof'd body. This is the decision log's "the transform emits it where an arm returns
  without calling k". Throw/abort arms then still run the body's defers (`abort_under_conversion`,
  `nested_aborts`, `discontinue/nested_after_outer`, `core/defer/*`). An arm that stores `k` is
  left alone, and dropping that continuation leaves its defers unrun, as today.

### 4.7 `return`, `break`, `continue` across a split
- **Inside a transformed function.** `return v` is `return k_ret(v)` (`return_in_converted_loop`,
  `nested_return`, `match/return_in_match`). `break` and `continue` call `after` and `again`, with
  the cleanups of the defers between them run first (4.8: wrapped exits, cps.ml:792-805).
  That covers `break_in_converted_loop` and `continue_in_converted_loop`.
- **Inside the run's body, leaving the function F that holds the run** (`return_out_of_run`,
  `return_in_inner_ctl_run`, `return_past_arm_defer`, `return_past_outer_ctl_run`,
  `return_in_inner_run`). `exits_across` is true. The transform declares in F, before the run:
  `var __left#n: Option<T_F> = Option.None;`. A crossing `return v` becomes
  `__left#n = Option.Some(v); return __discontinued();`, where the signal stands in for R and is never
  observed. Every arm of the runs between the `return` and F is regenerated so that each call of its
  continuation is followed by `if (__left#n.is_some()) { return __discontinued(); }` (named handlers:
  a `$leave#n` copy that takes the flag through `hv`). After the run expression, F gets
  `match __left#n { Option.Some(v) => { return v; } _ => {} }`. The arm's own defers run because the
  arm returns normally, and they run before F's caller sees v (`return_past_arm_defer`). The arm's
  sequel does not run (`UNREACHABLE` stays unprinted). This is cps.ml's stash/crossed (:1240-1296)
  with the frame unwinding replaced by early returns.
- A `return` in an arm is the method's own return, which answers the run.

### 4.8 `defer` and `discontinue`
- `defer d; rest` with a split in `rest` becomes `var armed#n = true;`, then the cleanup
  `{ if (armed#n) { armed#n = false; d } }` pushed on `cx.cleanups`, then `rest`. Each exit gets the
  cleanup before it: the end of the scope, `return` (calling `k_ret`), `break`/`continue`, and the
  discontinue path. This is cps.ml:727-847 as code. Each continuation re-sets `armed#n = true` on
  entry, so every pass releases what it acquired (`core/defer/defer_multishot_abort`). A `d` that
  itself splits is transformed with a continuation that does nothing on the unwind path
  (`defer_suspends_on_unwind`).
- `continuation_body(cx, body)` is
  `if (__is_discontinued(x)) { cleanups…; return <cx.ret or end>(x); } else { re-arm; body }`. A
  discontinued continuation runs what it holds and hands the same signal to its caller's
  continuation, up to the run's terminal continuation. The terminal continuation answers
  `__discontinued()` as R. `discontinue(k)` (built-in) calls `k(__discontinued())`, drops the result
  and returns `()` to the arm (`discontinue/discontinue`: arm before → cleanups → arm after).

### 4.9 Nested runs, unclaimed effects, the return clause
- Inside out: `processed` (4.1) lowers and transforms inner runs before this run sees the body.
  An inner run's output may still contain op calls of this run's effects, inside its continuation
  lambdas and its arms. This transform rewrites them like any other code in the region. That is
  why the output of each transform must be ordinary typed code (Truth 1).
- An op of an effect not in `cx.bound` is code like any other: it is left in place and split by
  the enclosing run (`abandon_through_run`, `delim`, `generic/nested`). The root binds what is
  left. An op no run binds is "Unhandled effect" at Precheck, as today (`errors/unhandled`).
- `return (x) { e }` makes the terminal continuation `(x) => e`. Otherwise it is `(x) => x` for a
  valued body, and `(_) => ()` for unit.
- `two_runs_one_expr`/`run_value/two_in_one_expr` need nothing: each run is its own expression
  (`(() => …)()`), with no shared evidence name (cps.ml:52-59's trap is gone).

## 5. Requirements for the Reflection slice (02)

- **R1 `processed(body: List<Stmt>, bound) -> List<Stmt>`**, a native callable from a meta block. It
  processes a quote at the meta block's *enclosing* run-time scope (like 02:I3 `Core.type_in`), under
  the key extended by `bound`, with the expected type R, and it returns the processed surface form.
  This is the one capability not in 02's list. 02 gives `declof` of a *declaration*, and the body is a
  quote.
- **R2 Types on processed code.** The transform needs the callee's row on every call, the type of
  every `var` and lambda param, and every function's ret and row. Either (a) `Expr` gains
  `ty: Option<TypeExpr>`, None in a quote and Some in processed code, or (b) processed surface is
  fully written: every `Let` annotated, every `Lambda`/`Fn` signature with `ret` and a closed `row`,
  and every non-name callee bound to an annotated `let`. **Prefer (a)**: (b) makes `processed`
  re-ANF the program, and its output depends on the core's printer.
- **R3 `declof` of an instance by Name** (02:I8, step 7) and of a method instance. The signature
  must be fully written, rows included (01:T5 closes them).
- **R4 Fresh, unwritable, hygienic names** for locals (`k`, `join`, `loop`, `armed`, `__left`)
  and for generated globals (`f$cps#n`), plus an `ExprKind` for a reference to a resolved
  declaration or instance that no local can shadow. Generated code calls `H.ask` and `f$cps#n`
  inside user bodies (memory: library-method-name-capture; 02:T11 `#` names are rejected by
  `as_name`).
- **R5 Reading an op call.** In processed surface, a receiverless op call is distinguishable from an
  ordinary call: `ExprKind.Call(Var(Ask.ask)…)` with the callee resolved to (trait, method), or a
  new `OpCall(TypeExpr, Name, List<Expr>)`. Prefer the resolved reference (R4), plus
  `declof(Ask)` → `TraitDecl` with `MethodSig.attrs` (02:I9).
- **R6 Meta state across calls**, or M3. Either a module-level `var` in a library module that
  survives between meta blocks of one program, or an API that registers and finds a generated
  sibling instance.
- **R7 `TypeExpr` for rows and arrows round-trip.** `TypeKind.Function(params, ret, row)` with an
  open row variable `ρ` for `(A) -> <ρ> R` (`TypeKind.Row`), and `Types.to_type_expr` (01) for writing
  inferred types into generated signatures.
- **R8 A block expression**, `ExprKind.Block(ValuedBlock)`, or acceptance that an expression
  `meta` splices `(() => {…})()` (D2).
- **R9** Static param **packs** of types (`effect_transform<R, ...H>`, ast.ml:100 `sp_pack`), and
  `declof(H)` returning the impls of a type (`impl EffectHandler<E, R> for H`, `impl E for H`)
  so that `with H` can be computed.
- **R10** 02:I6/I7/I9 as written: meta as an expression, gen of a syntax-valued call, a trailing
  value in `code {}`, meta in a trait body. EffectHandler's `str(E)` problem (02:T7): the stdlib
  version uses `fail("not a trait")`.

## 6. Interfaces from the Metaprocess-core slice (01), and runtime built-ins

- **M1 `Key.Handler(label, ty)`** and `ctx.effects` (01:§Effects). Additionally, the call branch
  resolves an **unmarked** op call whose label is bound to `H.op` (the impl method instance), with
  `hv` threaded as a leading argument through every instance under the key: instances at
  `{Log = H}` take `hv: H` first. A `@ctl` op call is left as an op call, typed with the op's
  signature.
- **M2 Rows on processed code**, zonked and closed (01:T5), including a row's handled labels. A
  function's row after binding keeps its bound labels, because the transform reads them (4.2). After
  a transform, a gen'd `f$cps` has its `@ctl` labels discharged.
- **M3 Decl cache** entries for gen'd instances (`register`, 01:S4). `declof` of a `Walking` instance
  is an error (02:§3.6), so a recursive callee is transformed from the cache reservation, never
  re-declof'd.
- **M4 Expected type** for the run (R) and for the spliced output.
- **M5 Precheck types `run` by its fixed rule** (`check_run`). If Precheck erases it as meta,
  every function containing a run loses its row, and code nothing reaches stops being checked
  (T11).
- **M6 Prune** drops instances made only by `processed` or `declof` (02:T4). Otherwise the original
  untransformed `f` at `{Ask = H}` is emitted beside `f$cps`.

**Built-ins (interp.ml).**
- **B1 Tail calls for every closure.** `return f(args)` and a final expression-statement call in a
  closure body are tail calls when the block has no pending `defer`. Today only `Cont`/`Frame` get
  tail calls (`tail := not returns`, interp.ml:318). Ordinary closures always catch
  `Return_value` (:333), so a CPS loop of plain lambdas would grow the OCaml stack per iteration. Keep
  `bounce` (:358) as the trampoline without the scope lists. The pending-call protocol (:410-430)
  stays.
- **B2 The discontinue signal.** `__discontinued<T>(): T` is the identity-compared value from
  interp.ml:41. `__is_discontinued<T>(x: T): bool` replaces :175. `discontinue<A, R>(k: (A) -> R): unit`
  replaces :172 (calls `k(signal)` and drops the result). These live in builtins.ml and are declared in
  the prelude.
- **Deleted:** `Aborted`, `active_scopes`, `under`, `carry_on`, `is_continuation`, `leaving`,
  `Scope`/`Abort`/`On_unwind`/`Cont`/`Frame`. Scope re-entry (Algebraic Effects.md "A continuation
  puts back the frames") is replaced by lexical CPS with honest rows (Q2).

## 7. EffectHandler (`stdlib/effects/EffectHandler.cx`)
This is the doc's code verbatim, with two changes. `resume`'s type gets the row parameter
(`TypeKind.Function([resumes], answer, [Applied { name: "ρ"… }])`, R7), so that
`trait EffectHandler<E, R, ρ>` is instantiated with ρ = the run's outward row. ρ is filled by the run,
never written by users (02:Q2 open slot). And `fail(…)` replaces `str(E)` (02:T7). A fixture
`tests/effects/handler/effect_handler_shape` prints `--dump-code` of `EffectHandler<Effect, String, <>>`.

## 8. Ordered steps
Each step ends with `dune build` passing and `dune test --force` at the stated delta. New fixtures go
in `expected_failing` with the step they wait on, first (CLAUDE.md). The steps assume 01:S1-S9 and
02:1-9 have landed, or name where they wait.

- **S0. Fixtures first.** Add, in the new syntax, under `tests/effects/v2/` (moved into place in S9):
  the Working Example (`asked / 5 / hehe / complete`), `resume_returns_block_value` (multi-shot,
  each `k` returns its own result), `ctl_and_unmarked_in_one_effect` (the doc's `Effect` with `log`
  and `choose`), `named_handler_generic` (`Picker<R>`), `with_binds_several`,
  `handler_captures_by_reference`, `throw_fresh_result` (`return throw("x")` at int and at string),
  `errors/handled_twice`, `errors/with_binds_nothing`, `errors/ambiguous_operation`. All go in
  `expected_failing` "Waiting S7".
- **S1. B1 tail calls** (interp.ml). Generalize `exec_last` to `Return (Some call)`, and to the final
  `Expr call` of any closure with no pending defer. Test it with a new
  `tests/core/functions/tail_call_deep` (1e6 mutual calls through lambdas). Breaks: nothing.
- **S2. B2 builtins** next to today's `discontinue_name` handling. Breaks: nothing.
- **S3. Parser and AST, dual mode.** Parse `trait` methods with `@ctl`, `run<R>`, `handle<T> {defs}`,
  `with T`, `discontinue(k)` and `k(x)` alongside the old forms. The new forms parse to the new
  `handler_clause`. Old and new coexist only inside this branch's history. Nothing ships dual.
  Ast.cx/syntax.ml/Printer.cx get the new `HandlerClause`. Breaks: `tests/meta/syntax/round_trip`
  output (update it).
- **S4. Typecheck: traits as effects** (§3.1, §3.2). Receiverless trait-method calls, rows of trait
  labels, op own-static-param quantification, the never-resuming test for `defer`. The old
  `Effect_decl` path is still there. Fixture: `v2/throw_fresh_result` checks (with `--dump-types`),
  but cannot run yet.
- **S5. `EffectHandler` and `check_run` for the new clauses** (§3.3, §7). Waits on 02:I5/I9.
  `handle<E>` makes the anonymous type and impl. `with H` resolves through R9. Two-handler and
  nothing-bound errors. Handler values (§3.5 interim). Fixture: `handler/effect_handler_shape`
  passes, and `v2/errors/*` pass.
- **S6. M1 unmarked binding.** A run whose handlers have no `@ctl` op (Console, Log, Ask-as-fn) is
  lowered (§3.4) to a meta block whose transform only processes the body (4.1, early return).
  Unmarked calls become `H.op(hv, …)` through the key. Waits on 01:Key.Handler. The old
  `cps.ml` still handles old-syntax runs. Fixtures: `v2/handler_captures_by_reference` and the
  migrated `log/log`, `handler/handler` and `methods/methods` pass.
- **S7. `effect_transform` core** (§4.1-4.5), in this order, each with its migrated fixture going
  green: straight-line splits (`ask`, Working Example), if/match joins (`match/*`, `nested_return`),
  `while`/`for` (`logic/*`, `generic/generic`, `return_in_converted_loop`), break/continue,
  conditions and logic (`suspend_in_*`), expression ANF (`suspend_in_field_assign`/`variant`/
  `record`/`tuple_destructure`), declof'd callees and recursion (`recover`, `stream`), multi-handle
  (`multi_handle/*`), generic effects (`generic/*`).
- **S8. Composition and control** (§4.6-4.9): honest rows on `k` (Q2), arms transformed by outer
  runs (`resume_through_run`, `inner_run_suspends_outward`, `handler/arm_reaches_outer`,
  `multishot_sequel`, `abandon_through_run`, `delim`), discontinue insertion and defers (`deferred/`,
  `discontinue/`, `abort_under_conversion`, `nested_aborts`, `final/*`, `core/defer/*`), crossing
  returns (`return_out_of_run`, `return_in_inner_ctl_run`, `return_past_arm_defer`,
  `return_past_outer_ctl_run`, `return_in_inner_run`), and the return clause (`run_value/*`).
  In-region function values (`fn_values/multishot_closure`, `in_list`, `in_tuple`, `through_index`,
  `wider_row*`, `named_as_value`, `closure_in_arm`).
- **S9. Function values from outside the region** (Q1's chosen option), then **stdlib and fixture
  migration in one change** (decision log: no compatibility sugar). Rewrite the 19 stdlib files and
  178 fixture files with a throwaway script in `scratch/` (`effect`→`trait`, `ctl`→`@ctl fn`,
  `final ctl f(…)`→`@ctl fn f<T>(…): T`, `fn op`→`fn op`, `handle E { ctl f(x) { … resume v; … } }`→
  `handle<E> { fn f(x, k) { … k(v); … } }`, `resume;`→`k(());`, `discontinue;`→`discontinue(k);`,
  `handler n : E {…}` + `with n`→`type N {}` + `impl E for N {…}` + `with N`). Hand-fix the `.err`
  files. `__root` (prelude.cx:54) is restructured per Q1. Async (Task.cx) last.
- **S10. Delete the old path:** cps.ml, `aborts`/`Cont`/`Frame`, the old effect AST, the old
  parser paths and keywords, typecheck's arm machinery, interp's scopes, and Verify's
  `Cps.fields_of` (verify.ml:42 → `Types.named_fields`). Move `tests/effects/v2/*` into place. The
  `internal-docs` rewrites (Algebraic Effects.md, Continuations and Tasks.md, Async.md) are listed
  for the user, not made here.
- **S11. Measure** (§10) on `tests/stdlib/net/*`, `tests/stdlib/async/*` and the largest example.
  Record the numbers in the PR.

## 9. Fixtures at risk (133 `.cx`; 118 runnable stems, 21 error stems, multi-file cases counted once)

| Group | n | Risk | Why |
|---|---|---|---|
| ask, log, exception, delim, flip, recover, stream, logic/2, match/3, nested_return, multi_handle/2, generic/10 runnable, run_value/6, two_runs_one_expr, callee_checked_*/2, forward_call_keeps_own_row, nested_control/4, methods/methods | ~42 | low | Lexical CPS of named callees. Only the syntax changes. |
| suspend_in_* (9), return/break/continue_in_converted_loop | 12 | low-med | §4.4 ordering. A port of cps.ml's cases with a direct test each. |
| resume_through_run, abandon_through_run, multishot_sequel, inner_run_suspends_outward, handler/arm_reaches_outer, nested_aborts, abort_under_conversion | 7 | med | Depend on Q2 (honest rows), so that the outer transform splits arms and continuations. |
| return_out_of_run, return_in_inner_ctl_run, return_past_arm_defer, return_past_outer_ctl_run, return_in_inner_run | 5 | med | §4.7 arm regeneration. Named handlers need a `$leave` copy. |
| deferred/deferred, discontinue/2, final/abort, final/in_loop, core/defer/* (outside effects/) | 6+ | med | Discontinue insertion and the signal protocol. `deferred` needs `List<() -> <Console> unit>` (Q2). |
| **abort_after_resumption** | 1 | **high** | The stored continuation is called after both runs exit, while it performs Error. With honest rows it is rejected (Q2). With pure rows inside-out typing fails. The fixture must change. |
| **fn_values/** spawn, nested_spawn, suspending_closure | 3 | **high** | The lambda is created outside the run's function (Q1). |
| fn_values/ in_list, in_tuple, through_index, multishot_closure, named_as_value, closure_in_arm, wider_row* | 8 | med | In-region function values (4.6). Written types in the region are rewritten. |
| **methods/suspending_receiver** | 1 | **high** | A trait object with a `@ctl` method (D6: rejected for now). |
| async/2, tests/stdlib/async/*, tests/stdlib/effects/iterator* | ~15 | **high** | Q1 (tasks are values in lists), Q2 (queue types), and multi-handler roots. |
| rows/9 | 9 | med | Trait labels in rows and receiverless op typing. `rows/trait_row_argument` and `returned_closure` exercise row unification through function values. |
| handled_in_import/4, named_import/2, qualified_op/3, nested_decls/2, handler/handler | 12 | low-med | Imports of traits and op qualification. `nested_decls/handler_in_block` becomes a local type, which needs local type declarations (check 01:§2.6). |
| errors/21, generic/errors/4, final/errors/1, handler/errors/1 | 27 | **every `.err` changes** | `handler_widens`, `final/errors/resumes`, `discontinue_outside_ctl`, `unknown_handler`, `non_exhaustive`, `no_such_operation` and `duplicate_operation` lose their meaning or become impl/type errors. `arm_settles_*`/`arm_ties_op_param` need the same rule on impl methods of a generic op (`suspend<T>`). Keep the stems and rewrite the expectation. Delete `handler_widens` (no arm kinds). |
| **Every program** | all | **high until Q1** | `__root` receives each statement as a value. |

## 10. Performance

- **Compile time.** The transform is interpreted Cronyx. Assume 50-200x slower per node than
  cps.ml in OCaml, plus a second full check of everything it emits (Truth 1), plus R1's processing
  of each run body. Work is proportional to Σ (decl, handler types) over functions reaching a bound
  `@ctl` op, not to the program. Levers: (1) answer-generic `f$cps<__R>` (4.5), so R does not
  multiply; (2) the cache is shared across `__root` instances, since every statement binds the same
  root handler types; (3) the early return when no `@ctl` op is reachable, which covers
  Console/Logger/Env/Time/Random/Args/Dirs; (4) no work for unreached code (Prune). Risk: `Throw`
  becomes `@ctl` (§3.2), so every function that can fail is transformed under the root. Today that
  costs nothing (evidence plus unwind, Algebraic Effects.md §"final ctl earns its place"). Fs, Net
  and Process (prelude.cx:62-71) are `ctl` already. Artifacts store unmetaprocessed packages
  (CLAUDE.md), so the cost is paid on every build. S11 measures it, and a regression over ~3x on
  `tests/stdlib/net/*` is a stop.
- **Run time.** A transformed loop allocates a closure per iteration and relies on B1. A throwing
  path is CPS where it used to be an exception. The follow-up, not part of this base: a second
  library strategy for never-resuming ops (§3.2's parametric-T test). It checks the result signal
  after each call (`if (__is_discontinued(r)) return r;`) instead of building continuations, so loops
  and the shape of the code stay as written. It is opt-in from `effect_transform` by the op's type,
  which is not a hook.

## 11. Traps in the current code

- **T1 Global op namespace** (typecheck.ml:139-143, :4021). Ops are global names today. As trait
  methods called without a receiver, they meet program functions of the same name. Lookup order:
  value first, then effect method. The stdlib must avoid common names (memory: library method name
  capture). `yield`, `write`, `record`, `now` and `open` are all candidates.
- **T2 Named handlers are copied textually** (desugar.ml:262-270, keyed by bare name and
  collected from any depth, :274). Nothing today exercises a named handler with state or with
  captures. New named handlers are types, so `nested_decls/handler_in_block` needs local type
  declarations.
- **T3 `self` is positional by name** (typecheck.ml:1043,2267,2936). Effect methods have no `self`,
  so they are static trait methods. Check that static trait methods dispatch through an impl
  for a *type* (`H.ask`) rather than through a value, which 01's call branch must allow.
- **T4 Resolve hoists every `Run_expr` into a temp** (resolve.ml:377-428). Order-sensitive code
  that relied on the temp (`run_value/two_in_one_expr`) now evaluates in place, left to right.
- **T5 Implicit static params** (CPS Migration.md "A parameter with no type written is an implicit
  static param"; 01:D4 rewrites them at collect time). A `handle` block's untyped method params must
  take the trait's types *before* 01's D4 runs, or each handler method becomes generic and its
  continuation's type is a static param.
- **T6 `Cps.fields_of` widens record fields globally** (cps.ml:1483-1491, verify.ml:42). Verify
  depends on CPS state from the last conversion. Once CPS is gone, record field function types must
  already be the rewritten form wherever the transform changed them (4.6), or Verify reports a
  mismatch.
- **T7 Continuations share mutable locals across shots.** Capture is by reference, and today's CPS
  has the same behaviour. A loop counter declared before a multi-shot split is shared by both
  shots (`logic/*`, `flip`). Keep it: per-shot copies would change `multishot_sequel`.
- **T8 `Return_value` is caught by every closure** (interp.ml:333). A generated continuation must
  never contain a bare `return` that means F. Every crossing `return` goes through §4.7.
- **T9 Evaluation order** is explicitly left to right in the interpreter (interp.ml:242 comment,
  `eval_all` :336) and right to left in OCaml. The transform must not reorder. 02:T10 is the same trap in
  the walk.
- **T10 Tail position and defers.** `run_block` disables tail calls when the block has defers
  (interp.ml:398). §4.8 turns defers before a split into flags plus explicit cleanups, so generated
  continuations have no `defer`. Check that the transform never emits `defer` into one, or B1 is
  lost there and long loops overflow.
- **T11 Precheck erases meta.** If `run` lowered to meta before Precheck, Precheck would treat run
  bodies as unknown. Precheck must type the `Run_expr` node with `check_run` (M5).
- **T12 The `__root` row** has 14 labels (prelude.cx:55). Every statement's instance key carries the
  root handler bindings. With 01:Q1(b) defaulting `X`, `Throw<unit>` is bound per statement.
  Make sure the transform's cache key uses handler *types* only, so all statements share entries.
- **T13 `discontinued` is a `Variant`** (interp.ml:41). `__is_discontinued` must use physical
  equality (`==`) and must not go through structural `Eq`, or a user `discontinued` variant
  matches it.

## 12. Questions (each changes the base implementation)

**Q1. A function value that performs a bound `@ctl` effect and comes from outside the run's
region.**
```cronyx
fn spawn(task: () -> <sched, Console> unit) {
    run { task(); } handle<sched> { fn tick(k) { queue.push(() => k(())); } }
}
spawn(() => { counter("A"); });          // the lambda's code is never in a region `sched` is bound for
```
The same holds for `__root(main)` (so every program), `attempt(f)`, `iterator(producer)`,
`block_on(main)`, `Task.all(tasks: List<…>)` and `scope`'s `start(task)`.
- (a) **A static function argument.** A parameter of function type whose row holds an effect the
  callee binds in a run makes its argument part of the key: the lambda's code is static and its
  captures are a value. This is the dual of the settled handler-capture rule. `declof` then reaches
  the lambda. It works for literal and forwarded arguments (`__root`, `attempt`, `rethrow`,
  `spawn`, `iterator`, `block_on`), costs one instance per call site, and keeps multi-shot. It cannot
  express a list of tasks (`Task.all`, `race`, `interleaved`, `scope.start`), which would be
  rejected ("a function performing '@ctl' 'suspend' cannot be stored where no run reaches it").
- (b) **A built-in CPS of such lambdas** in OCaml, by type, at creation. That keeps part of cps.ml
  (`widen`, :122), contradicts "cps.ml is replaced", and the conversion needs a handler-independent
  form, so dispatch is dynamic and the answer is unit with a temp.
- (c) **A built-in one-shot capture for values**, using OCaml 5 effects in the interpreter: an op
  call no transform reached performs dynamically. This is the "stack-switch primitive" that
  Vocabulary.md and Async Strategies.md:192 already call a built-in. Multi-shot through such values is
  lost (no fixture needs it, and Async Strategies.md's open question leans the same way), and the
  native backend owes stack switching.

**Recommend (a) as the base, with (c) only for values (a) rejects.** `__root` and the common
higher-order stdlib functions stay static and multi-shot. Async's task lists are one-shot by nature
("Async's suspend resumes once, but later"). Without (c), Task.cx's `all`/`race`/`scope` must be
redesigned around static task arguments, which is not in this slice.

**Q2. The continuation's row.**
```cronyx
var pending: List<() -> unit> = [];
run { run { work(); } handle<E> { fn op(k) { pending.push(() => k(())); } } }
handle<Error> { fn throw<T>(m, k) { print("caught: " + m); } }
pending[0]();     // today: "caught: boom", because the continuation carries its handler
```
- (a) **Honest (Koka):** `k: (A) -> <ρ> R`, with ρ the run's outward row. Each transform's output
  type-checks inside out. An outer transform splits arms at `k(…)`, so the arm's sequel order is
  right by construction. Stored continuations carry ρ: `deferred/deferred` and Task.cx's
  `ready`/`stop` need `<Console>`/`<E>` written, and Yield.cx already writes `<E>`. Calling one after
  its outer run has exited is "Unhandled effect", so `abort_after_resumption` and Continuations and
  Tasks.md's "resume contributes nothing to a row" change.
- (b) **Pure, as today.** Under inside-out transformation, the inner output passes an
  `<Error>`-performing lambda where a pure `(A) -> R` is declared. That is a type error at the first
  nested run unless typing is suspended for generated code, which is against Truth 1. Making it work
  would mean a continuation type distinct from a function type, plus closure-CPS at capture, which
  re-runs the sequel per outer resumption (Algebraic Effects.md:339-350).

**Recommend (a).** It is the only one consistent with Truth 1. `abort_after_resumption` gets
rewritten to drain inside the Error run, and the spec line it illustrates ("still unwinds to its own
run's handler") holds there.

### Defaults (one line each)
- **D1** `effect_transform<R, ...H>(body, values, clause)` generalizes the doc's `<E, H>`. E is read
  from H's impls, so one transform per run covers multi-handle with arms outside the run.
- **D2** An expression-position run splices `(() => { … })()` when it needs statements, until R8.
- **D3** The `return (x) { … }` clause is kept, as the terminal continuation.
- **D4** An effect is a trait whose methods take no `self`. A trait mixing both is not an effect,
  and "is not an effect" is an error in a row.
- **D5** A named callee splits if its row holds a bound effect that has any `@ctl` op. Only op call
  sites are split per op.
- **D6** A trait-object method whose row holds a bound `@ctl` effect is rejected with a diagnostic.
  `methods/suspending_receiver` goes to `expected_failing` "trait objects under effect_transform".
- **D7** Discontinue is inserted only where an arm's body never names its continuation (syntactic).
- **D8** R is inferred when not written. `run<R>` is required only where inference cannot settle it.
- **D9** `Throw`/`exit`/`failed` become `@ctl fn f<T>(…): T`. The per-call-site result type is
  kept, and the cheap unwind is not (§10 follow-up).
- **D10** The interim handler value is a record of closures (§3.5). Named-field handler types
  follow once 01 has impl-method instances.
