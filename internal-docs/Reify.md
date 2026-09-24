# Reify

Turning a compile-time value back into the syntax that denotes it.

Any stage holding a value that has to end up *in the program* needs this. Metaprocessing needs it for `gen` — a meta-bound name, or a subexpression promoted out of the meta scope, is written back into the code it emits — and that is also how a static argument computed in a meta block, `fib<n - 1>`, reaches the instantiation it asks for. Constant folding would need it to write a computed result back as a literal. Same operation in each case, so it is one facility.

Inside a `meta` block a value is dynamic; written into what a `gen` emits, it is static. Reification is how a value crosses that way, and how it crosses is decided per type.

## A type says how it is written: `Reifiable`

```cronyx
trait Reifiable {
    fn reify(self): Code;
}
```

A type that can become syntax implements `reify`, and it returns the `Code` that rebuilds it. The compiler supplies it for the primitives, tuples and arrays, as it does the operator traits; `Code` reifies to itself and `Name` to the identifier. A program's own types get it by deriving it, as they get `Eq`:

```cronyx
derive Reifiable for Point;
// generates, roughly:
impl Reifiable for Point {
    fn reify(self): Code {
        var x = self.x.reify();
        var y = self.y.reify();
        return code(new Point { x: x, y: y });
    }
}
```

**Why a trait rather than a structural walk.** Only the type knows what its value means as syntax. A `List` is a backing array and a count, and written out structurally it comes back as that record — the wrong type, carrying the spare capacity behind `count`. A named type comes back as an anonymous record and loses its name. `reify` lets `List` write itself as the literal that builds it and `Point` as `new Point { … }`.

**Why it returns `Code`.** It is what a `gen` splices, and what `code(…)` already builds: a `Code` held in a meta variable splices into `code(…)`, so an impl assembles its syntax the way any other meta code does. Template Haskell's `Lift` (`lift :: t -> Q Exp`, with `deriving Lift`), Scala 3's `ToExpr` and Rust's `quote::ToTokens` are the same shape.

**Why it is derived explicitly.** A type says it can become syntax the way it says it can be compared, so a plain record is not reifiable until it asks to be.

**What it settles.** A value that cannot cross is a type error in the meta program — a `gen` reading `f` asks for `Reifiable` of its type — rather than something found while the block runs. A trait object can be written out when its trait extends `Reifiable`, since its table then carries `reify`, which answers [Meta Scope and Instantiation](Meta%20Scope%20and%20Instantiation.md)'s open question.

**What it needs.** A collection's `reify` has a variable number of parts, and `code(…)` has no form for "a list literal of these `Code`s", so it needs a splice form or a prelude helper. And it is built with the rework of `Code` itself ([TODO](TODO.md), "`Gen` as an effect"), since both change what `Code` is.

## What is built: a structural walk

`Metaprocess.literal_of` asks the value as the `gen` runs, by its shape:

| Shape | Written as | Reifiable when |
|-------|-----------|----------------|
| `int`, `float`, `string`, `bool`, `char`, `unit` | a literal | always |
| tuple | a tuple literal | every element is |
| record, named product | a record literal | every field is |
| array | an array literal | every element is |
| `Code` | the syntax it holds | always |
| `Name` | the identifier | always |
| function | — | never |
| sum, trait object | — | not built |

`meta/02_gen/reify_list` and `reify_record` are the collections; `meta/02_gen/errors/reify_fn` is the failure, *'f' is a function and cannot be written into generated code.* A variant is the gap that matters: `Name::Variant(…)` is the obvious form and nothing needs it yet. A trait object is [Meta Scope and Instantiation](Meta%20Scope%20and%20Instantiation.md)'s open question.

So a user type is written out the moment its fields are — as a record, which is where the walk falls short:

```cronyx
type Vec2 {
    x: int,
    y: int
}

meta {
    var origin = new Vec2 { x: 0, y: 0 };
    gen var start = origin;      // emits: var start = { x: 0, y: 0 };
}

print(start.x);      // 0
```

And not, when something inside it is not:

```cronyx
type Handler {
    on_event: (int) -> unit
}
```

A function value has no syntax. Because the judgement is structural, the failure could name the path that caused it — `Handler.on_event`, not merely `Handler`. It names the variable the `gen` read instead, or says *This expression cannot be written into generated code.* for a promoted one.

## Builtins are the exception

For most types the syntax *is* the structure, so writing one out is a structural walk. The builtin collections are different: a `Set<int>` is not represented the way `[1, 2, 3]` is written, so reifying one means knowing its literal form. That knowledge already exists for the other direction — see [Collection Literals](Collection%20Literals.md) — and reify would read it backwards. Only arrays are written out so far.

## What it loses

**Sharing.** Writing a value out as syntax duplicates it, so two references to one array become two array literals:

```cronyx
meta {
    var xs = [1, 2];
    var pair = (xs, xs);
    gen var p = pair;            // two separate arrays at runtime
}
```

Since arrays have identity, that silently changes aliasing across the stage boundary. It is inherent to the approach rather than to this design — anything that moves values by writing them down has it — but it produces a confusing bug rather than an error, which is worth knowing.

**Cycles.** A value that reaches itself has no finite syntax, so this needs a cycle check rather than a stack overflow.

## Settled

**A type is not reified.** A `Type` is not a value in a meta block — `typeof(x)` has to be asked for `.name`, `.shape` or `.attrs` where it stands — so there is nothing to write back. A static type parameter reaches an instantiation by being written by name, not by being reified, and a type a generated declaration needs comes out of a shape as a `Name`.

**There is no size limit.** A compile-time value too large to write out produces a program too large to compile, and that is the author's problem.
