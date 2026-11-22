# ctl as a regular function: where we stopped (2026-11-20)

Exploration for the crusade to remove keywords and features from the language and do them as
functions + reflection. Nothing here is in `internal-docs/` yet.

## Proposal so far

The `Ctl` row label and its `Rewrite` impl from the first sketch are gone. The row says
only `<Ask>`, and `EffectHandler` is the handler trait (below).

- Rows monomorphize like static params (settled), and the key is `{label → handler}`,
  so `myFunc` is monomorphized once per handler and `ask()` resolves statically.
- Instances are checked inside Metaprocess (Truth 1), so rows are known on every call.
- An effect is a trait in a row (decided). A handler handles it one of two ways:

```cronyx
trait Ask { fn ask(): int; }

} handle<Ask> {                 // tail-resumptive: implements Ask itself, return is resume
    fn ask(): int { return 5; }
};

} handle<EffectHandler<Ask>> {            // control: implements EffectHandler<Ask, R>, R from the run
    fn ask(k) { var res = k(5); print(res); return "complete"; }
};
```

- `EffectHandler<E, R>` is generated from `E` by a meta block (the `# EffectHandler` section of CPS
  Migration.md). The continuation is its last parameter, and the name is free.
- NO HOOKS (user, 2026-11-21, absolute): the compiler never calls library code
  automatically on instances that meet a condition. The CPS rewrite runs only where
  code someone wrote calls it.
- Choosing the mode per handler is only sound because handlers are static. If a handler
  were a run-time value, every caller would have to be CPS'd. That commits to static
  handlers, though the user has not explicitly confirmed it, and it answers the old
  "handlers closing over run locals" question.

## Next traps, not yet raised

- Truth 1 requires `ask` to typecheck *before* the rewrite, which is why `resume` is a
  declared stand-in and not a keyword. Post-rewrite types change, `(T) -> <Ask> unit`
  becomes `(T, k) -> unit` when it calls a `@ctl` op, so the output is re-checked on the gen path.
- Section 3 of the old CPS Migration: `Cont`/`Frame`/`Abort` intrinsics a plain-lambda
  rewrite cannot express (`effects/abort_after_resumption`).
- Async's `suspend` resumes once, but later. Multi-shot `choose` is only in `tests/`.

Question 3 in `scratch/questions.md` (does inlining cover `ctl`?) is on hold behind this.

## 2026-11-21: the shape of a ctl

The handler question above is parked. The user is reconsidering the shape of `ctl`
first. **Use the existing effect/ctl/run/handle syntax in examples for now.**

Verified with bootstrap (`resume` is a statement, `resume 5;`, and has no value):

```cronyx
effect Ask { ctl ask(): int; }
var ret = run {
    var n = ask();
    print(n);
    "hehe"
} handle Ask {
    ctl ask() { print("asked"); resume 5; print("resumed"); return "complete"; }
};
print(ret);   // asked / 5 / resumed / complete
```

- A `return v` in a ctl arm answers the run, and overrides the block's own value, which
  the arm never sees.
- Falling off after `resume` keeps the block's value. Returning without resuming aborts
  with v.
- So, as the handler sees it: `(resume: (A) -> unit) -> R`. A comes from the operation
  (`ctl ask(): int`), R from the `run` (unit when the run is a statement).
- The user's `<EffectHandler<Int>> Unit` is right only for a statement run. A belongs in the label;
  R must come from the delimiting run.
- `Algebraic Effects.md:217` ("answer type is always unit") is stale; its own section at
  :246 and the compiler disagree. That's question 10 in questions.md.

Side request pending: an Obsidian plugin to run ```cronyx blocks via `cx run`
(registerMarkdownCodeBlockProcessor + child_process, desktop only, timeout). I offered
to build it, and the user hasn't said where it goes.

## 2026-11-21: `resume` returns the answer — fix in the upcoming change

The user expected `resume` to return a value, and decided to fix this in the upcoming
change rather than now. The target, from `CPS Migration.md`'s Working Examples:

```cronyx
effect Ask { ctl ask(): int; }
var ret = run {
    var n = ask();
    print(n);
    "hehe"
} handle Ask {
    ctl ask() {
        print("asked");
        var res = resume 5;
        print(res);
        return "complete";
    }
};
print(ret);   // asked / 5 / hehe / complete
```

- `resume v` runs the rest of the block with the op returning v, to the end of the
  block, and evaluates to what the block produced there ("hehe"). Each multi-shot
  resume gets its own result.
- That revises the shape above: **`(resume: (A) -> R) -> R`**, not `(A) -> unit`.
- Today (cx 0.0.29) this is a parse error at `var res = resume 5;`: `resume` is still a
  statement, which the `Algebraic Effects.md` decisions table also says.
- Work: parse `resume` as an expression; type it at the run's answer type R; have the
  continuation hand the block's value back to the arm. Add the example as a fixture first.

The Obsidian plugin is built: `editors/obsidian/` on branch `obsidian-plugin` (worktree
`.claude/worktrees/cronyx-obsidian-plugin`), symlinked into the internal-docs vault.
Run-on-click only.

## Decided 2026-11-21: resume returns the block's value

`resume v` is an expression: it runs the rest of the run block and returns the
block's value. The handler, as it sees the operation, is `(resume: (A) -> R) -> R`,
with A from the operation and R from the run. This is the standard typing of
delimited continuations, and it makes `resume` a plain function `(A) -> R`, not a
keyword.

```cronyx
var ret = run { var n = ask(); print(n); "hehe" } handle Ask {
    ctl ask() { print("asked"); var res = resume 5; print(res); return "complete"; }
};
print(ret);   // asked / 5 / hehe / complete
```

Next to settle: what falling off the end of an arm means now. Today it keeps the block's
value after a resume, and aborts without one.

## 2026-11-21: graduating if/else (and run/handle) as calls with clauses

The pattern is `name (args)? { block } ( label (args)? { block } )*`. The callee declares
the clauses it accepts (`elif(...)*`, `else(...)?`), and each block arrives as a closure.
`else if` is the `else` clause holding another call in its block position.

**Decided:** `return` ALWAYS returns from the enclosing function, even from inside a
clause block. `return@if` (Kotlin-style labelled return) is there when you want to be
specific. `break` and `continue` are presumably the same; this hasn't been confirmed.

Open: a lambda passed to a non-inline function, stored and called after the enclosing
function has returned, has no function left to return from. Also open: the parser can't
know which identifiers are clause labels.

**Decided (Kotlin's split):**
- `{ ... }` is always a lambda, and a bare `return` in it means the enclosing function.
  That is allowed only when the lambda is passed to an `inline` function (pasted in
  place). Passed to a non-inline function, a bare `return` is an error: write
  `return@name`, or let the last expression be the value.
- `() => { ... }` is an explicit function, and its `return` is its own.
- This changes today's behavior: `twice { return; }` currently leaves only the block.
  Verified, it prints in / in / 7.

**Parked 2026-11-21:** graduating if/else and run/handle is a TODO in CPS Migration.md.
It was waiting on a parse hook, which is now ruled out (no hooks, ever). A `clauses` list read by the parser, so
imports must be parsed before a file's statements. The user judged the cost too high for
now.

**Decided 2026-11-21:** a trait in a row is an effect. Its methods are called without a
receiver and answered by the enclosing handler, which implements `EffectHandler<E, R>` (or `E` itself, tail-resumptively).
The `effect` keyword graduates. As a bound or a type, a trait keeps its meaning. Recorded
in Vocabulary.md.

**Decided 2026-11-21:** the continuation's name is free. It is the handler's last
parameter, whatever it is called (`k`, `resume`). Note that `self` is NOT free in Cronyx
today: the checker recognizes a method by a first parameter named `self`. The user has
not said whether `self` should become positional too.

**Decided 2026-11-21 (supersedes handle<Ask> vs handle<EffectHandler<Ask>>):** the mode is set per
operation by an attribute, `@ctl fn choose(...)`, read as data by `EffectHandler<E, R>`'s meta
block. `handle<E>` always implements `EffectHandler<E, R>`: `@ctl` ops gain `k` and return R, and
unmarked ops are kept as written (tail-resumptive, returning exactly once whatever the
handler). An effect with no `@ctl` ops is its own EffectHandler. Only calls to `@ctl` ops split
their caller, which is finer than today's per-effect CPS (cps.ml:1). The cost: a `@ctl`
op always gets a k, even from a handler that only tail-resumes. The CPS Migration
`# EffectHandler` section has been rewritten to match. Ctl was renamed back to EffectHandler the same day.

**Decided 2026-11-21:** a named handler is a named type implementing
`EffectHandler<E, R>`. With no `@ctl` ops it implements E itself and works under any
run; with `@ctl` ops it is generic over R. A run binds every inline `handle<E>` and
every `with H`. `with H` binds every effect H handles that the body performs, and two
handlers claiming one effect in a run is an error. The doc and Vocabulary are updated.

**Decided 2026-11-21:** `run` stays a keyword for now, sugar with a fixed meaning (like
`+` → `Add`): `run<R> { body } handle<E> { ... }` means
`meta { gen effect_transform<E, H>(code { body }) }`. It isn't a hook. Graduating `run`
waits until the current work is done ("so we don't bite off more than we can chew").
The doc's EffectHandler section now says this.

**Decided 2026-11-21:** control flow keeps its current behaviour, and `tests/effects`
(133 fixtures) is the spec for effect_transform. The behaviours are listed in the doc's
EffectHandler section.

**Decided 2026-11-21 (closes the static-vs-value handler question):** a handler's TYPE
is static (key `{E = type}`, monomorphized, mode known). Its captured locals are a VALUE:
fields captured by reference, like lambdas (verified that lambdas already capture by
reference), passed as a parameter to the instances under the key. The stdlib needs this:
`stdlib/async/Task.cx:183` reads `cancelled` and `failure`, and about 20 fixtures do too.

**Decided 2026-11-21:** no compatibility sugar. The old syntax (`effect`, `ctl`,
`final ctl`, `resume x;`, `handler name : E`, `with name`) is rewritten immediately: the
stdlib's 17 effect/handler declarations and every fixture move to traits / `@ctl` / the
continuation parameter / named handler types in the same change.

**Adopted 2026-11-21 (to revisit after the base works):** one intrinsic,
`discontinue(k)`, which unwinds a continuation and runs its defers without resuming it.
The transform emits it where an arm returns without calling k. Tail calls are an
interpreter guarantee, not an intrinsic. Everything else of Cont/Frame/Abort should come
from the transform.

**Decided 2026-11-21 (U1):** a function argument whose row holds an effect the callee binds
in a run is part of the key: static code, captures as a value. Lists of tasks (Task.all,
race, scope.start) are deferred to expected_failing; dynamic capture vs redesign is decided
after the base works.

**Decided 2026-11-21 (U2):** honest continuation rows `(A) -> <ρ> R`; abort_after_resumption rewritten; CPS Migration.md and Vocabulary updated.

**Decided 2026-11-21 (U3):** gen of a call evaluates it if the callee returns a syntax type; otherwise it emits the call. Recorded in the Splice section.
