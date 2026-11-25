# Vocabulary

The words Cronyx's design uses, and the ones it avoids. When a term here and
another document disagree, update one of them.

## Language design

**Graduate**, **graduation.** Taking a concept or mechanic out of the compiler
and moving it into the standard library as ordinary Cronyx code. `ctl`
graduates when it is a library function, not a keyword. Graduation is the goal,
not a loss.

**Built-in.** A feature that cannot graduate yet, because library code cannot
express it. The stack-switch primitive a stackful strategy needs is one.

## Metaprocessing

**Metaprocess.** The function applied to each chunk of code — a statement, then
whatever it reaches — that leaves it type checked, monomorphized and free of
`meta`. See the Truths in [CPS Migration](CPS%20Migration.md).

**Processed code.** Code that has been metaprocessed. It is type checked,
contains no `meta`, and is monomorphized.

**Static param.** A parameter in a `<>` list, known at compile time: a type, a
value, or an effect row. See [Static Params](Static%20Params.md).

**Key.** The static params a declaration is metaprocessed at: `{T = int}`,
`{n = 3}`, `{Ask = Five}`. A declaration with no static params has one key, `{}`.

**Monomorphize.** Metaprocessing a declaration at a key. It is not a separate
step: a declaration is only ever metaprocessed at a key.

**Instance.** What monomorphizing produces: `helper$int` is `helper` at
`{T = int}`.

**Decl cache.** Every instance made so far, by declaration and key. A second
call at the same key reuses the instance.

**Prune.** Dropping every instance nothing in the processed program uses, so
an instance made only to answer a `declof` or a `typeof` is not emitted.

**Splice.** Replacing a node with what it stands for: a `typeof` with the type,
a `code` with its syntax as a value, a `declof` with the processed declaration,
a `meta` with what it `gen`'d. Splice knows the context, so code that does not
fit where it lands is an error there, never at `gen`.

**Quote.** `code(…)`: syntax as written, held as a value. Its children are not
processed until something `gen`s it.

**Expected type.** The type a parent passes down to a child before the child
is processed, from an annotation, a declared return type, a parameter type or a
field type.

## Effects

**Row.** The effects a function performs, written before its return type:
`fn f(): <Console> unit`. A row is a static param, so it is part of the key.

**Effect.** A trait used in a row. Its methods are called without a receiver
and answered by the enclosing handler.
The same trait as a bound (`<T: Ask>`) or a type (`x: Ask`) keeps its ordinary
meaning.

**Operation.** A method of an effect's trait, as its callers see it:
`fn ask(): int`.

**Handler.** What answers an effect's operations, chosen statically by the
`run` that binds it. It implements `EffectHandler<E, R>`. Written once and
reused, it is a named type bound with `with`, which binds every effect the type
handles that the body performs.

**@ctl.** The attribute on an operation that takes control of the continuation.
An unmarked operation is tail-resumptive: it returns exactly once, whatever
handles it.

**EffectHandler.** `EffectHandler<E, R>`, the trait a handler implements, generated from `E`: each
`@ctl` operation gains a continuation as its last parameter, whose name is
free, and returns the run's type (`fn choose(options: Array<int>, k: (int) -> R): R`);
every other operation is kept as written.

**Resume.** The rest of the run, as a function: it takes what the call site
receives and returns the run block's value. Its row is what the run passes
outward, `(A) -> <ρ> R`.

**Answer type.** What a `run` evaluates to, and so what `resume` and the
handler return. It belongs to the `run`, not to the operation.

**Strategy.** Library code that rewrites code, such as CPS for the code that
calls a `@ctl` operation. It runs only where code calls it.

## Avoided

**Template.** Poisoned by C++. Say monomorphize and instance.

**Comptime function.** There is no such category. There are functions, each
metaprocessed per key, and the functions a `meta` block calls, which run at
compile time as ordinary code.

**Demote.** Moving a feature into the library is a gain. Say graduate.
