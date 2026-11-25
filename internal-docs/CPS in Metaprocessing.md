# CPS in metaprocessing

Status: **proposed.** Nothing here is built. It moves the CPS rewrite out of the
compiler and into library code that the walk runs, so that `Ctl` is one
strategy among others, as in [Async Strategies](Async%20Strategies.md). It
assumes the walk already knows every function's effect row; how it learns them
is open, below.

## The problem

A `meta` block emits code only where it stands. CPS is not local: every
function whose row contains `Ctl` has to be rewritten, not only the operation
that names it.

```cronyx
fn ask<C: Ctl>(): int { print("asked"); resume(5); print("resumed"); }
fn myFunc() { var x = ask(); print(x); }
fn main()   { myFunc(); print("after"); }

fn for_each<T, E>(xs: Array<T>, f: (T) -> <E> unit): <E> unit {
    for (x in xs) { f(x); }
}
```

`ask` is the only one that mentions `Ctl`, but `myFunc` and `main` need
rewriting too, and so does the copy of `for_each` whose `E` is `Ctl`.

The target output is the same whatever the mechanism:

```cronyx
fn ask(resume: (int) -> unit) { print("asked"); resume(5); print("resumed"); }
fn myFunc(k: () -> unit) { ask((x) => { print(x); k(); }); }
fn main() { myFunc(() => { print("after"); }); }

fn for_each$Ctl<T>(xs: Array<T>, f: (T, () -> unit) -> unit, k: () -> unit) {
    fn go(i: int) {
        if (i == xs.length) { k(); } else { f(xs[i], () => { go(i + 1); }); }
    }
    go(0);
}
```

```
asked
5
after
resumed
```

## Proposal: a strategy is a static param, and `run` scopes it

Instantiating a function with a strategy is the rewrite. A strategy is a set
of comptime hooks:

```cronyx
import { Fn, Stmt, Expr, rowOf } from "std/compiler/Ast";

strategy Ctl {
    comptime fn rewrite(f: Fn): Fn {
        if (f.mentions("resume")) {
            return f.addParam(code(resume: (f.ret) -> unit)).retUnit();
        }
        return f.addParam(code(k: (f.ret) -> unit)).withBody(cps(f.body, code(k)));
    }
}

comptime fn cps(ss: Array<Stmt>, k: Expr): Stmt {
    for (i in 0..ss.length) {
        if (rowOf(ss[i]).has(Ctl)) {
            return splitCall(ss[i], cps(ss[i+1..], k));
        }
    }
    return code({ ss; k(); });
}
```

It can be passed explicitly, the way any static param is:

```cronyx
fn myFunc<S: Ctl>() { var x = ask<S>(); print(x); }
```

Alternatively, `run<S> { }` delimits it. The block is rewritten, and any callee it reaches
whose row contains `S` is instantiated with `S`. The same applies inside that
copy, so the chain needs no annotations:

```cronyx
fn main() { run<Ctl> { myFunc(); print("after"); } }
// myFunc → myFunc<Ctl>, ask → ask<Ctl>, for_each → for_each[E=Ctl]
```

`for_each` names no strategy. Its row variable `E` is bound to `Ctl` at the
call, and that binding is part of the memo key:

```
(fn, type args, static args, {row label → strategy})
for_each[T=int, E=Ctl]
```

The key goes in before the body is rewritten, so a recursive call reuses the
copy instead of making a new one.

**What the language provides:**

1. A `strategy` kind of static param. When the walk instantiates `f<S>`, it
   runs `S.rewrite(f)`.
2. Row-to-strategy binding. Inside `run<S>`, or in a copy made with `S`, a
   callee whose row mentions `S` is instantiated with `S`, through row
   variables too.
3. A comptime `rowOf` on `Ast` nodes.

## Alternatives

**A global row hook.** The walk calls the strategy on every instance whose row
contains it, with no `run` to scope it:

```cronyx
impl RowRewrite for Ctl {
    fn op(f: Fn): Fn { return f.add_param(code(resume: (f.ret) -> unit)); }
    fn body(f: Fn, rowed: (Call) -> bool): Fn { return cps(f.add_param(code(k: () -> unit)), rowed); }
    fn boundary(c: Call, rest: Expr): Expr { return c.add_arg(code(() => { rest; })); }
}
```

This is the proposal with the scope removed. `boundary` is what `run` would
have been, applied implicitly wherever a call leaves the row.

**The compiler hands each call site its continuation.**

```cronyx
impl Lowering for Ctl {
    fn sig(f: FnDecl): FnDecl { ... }
    fn site(c: Call, k: Cont): Expr { return c.add_arg(code((k.hole) => { k.body; })); }
}
```

Building `Cont` is most of CPS: normalising expressions, turning loops into
recursion, and translating `return` and `break` across the split. All of that
stays in the compiler, and the library only picks the encoding. A
Kotlin-style state machine needs the whole function, not one call at a
time, so this shape fits `Ctl` and nothing else.

## Problems every design has

**Function values change type.** `(T) -> <E> unit` becomes
`(T, () -> unit) -> unit`. A callback stored where no call site reaches it
cannot be found:

```cronyx
type H { f: () -> <E> unit }
```

The same holds for a trait method called through a trait object. Each of these
is either an error or a reason to keep function types' rows visible to the
rewrite.

**Two strategies in one row don't commute.** For `<Ctl, KotlinAsync>`, CPS
then state machine is a different program from state machine then CPS. Either
a row orders its strategies, or a row holding two rewriting strategies is
rejected.

**`inline` runs before the rewrite.** Inlining `ask` into its caller pastes a
`resume` that nothing binds. Either inline expansion moves after strategies,
which is also what lets two state machines merge into one frame, or an
operation cannot be `inline`.

**Control flow across a split.** A loop becomes recursion, and the stack grows
without tail calls. A `return` or `break` after a split has to be translated.
A `var` assigned after a split has to be boxed, which meets
[Boxing and References](Boxing%20and%20References.md).

## Open

How the walk knows a row. Inference is what says `for_each`'s `E` is `Ctl`,
and inference runs after the walk. `Precheck` already infers the whole
program before it, and could supply rows everywhere a meta block cannot
change them, with an annotation required where one can.
