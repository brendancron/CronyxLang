# Reify

Turning a compile-time value back into the syntax that denotes it.

Any stage holding a value that has to end up *in the program* needs this. Metaprocessing needs it for `gen`, monomorphization needs it to bake a static argument into a specialized copy, and constant folding needs it to write a computed result back as a literal. Same operation in each case, so it is one facility rather than three.

## Reifiability is derived, not declared

It is a question about a type, not a capability a type supplies, so nothing is written to opt in:

| Shape | Written as | Reifiable when |
|-------|-----------|----------------|
| `int`, `float`, `string`, `bool` | a literal | always |
| tuple | a tuple literal | every element is |
| record | a record literal | every field is |
| named product | `Name { field: … }` | every field is |
| sum | `Name::Variant(…)` | every payload is |
| array, list, set, map | a collection literal | every element is |
| function | — | never |

A user type is therefore reifiable the moment its fields are:

```cronyx
type Vec2 {
    x: int,
    y: int
}

meta {
    var origin = Vec2 { x: 0, y: 0 };
    gen var start = origin;      // emits: var start = Vec2 { x: 0, y: 0 };
}

print(start.x);      // 0
```

And not, when something inside it is not:

```cronyx
type Handler {
    on_event: (int) -> unit
}
```

A function value has no syntax. Because the judgement is structural, the failure can name the path that caused it — `Handler.on_event`, not merely `Handler`.

## Builtins are the exception

For most types the syntax *is* the structure, so writing one out is a structural walk. The builtin collections are different: a `Set<int>` is not represented the way `[1, 2, 3]` is written, so reifying one means knowing its literal form. That knowledge already exists for the other direction — see [Collection Literals](Collection%20Literals.md) — and reify reads it backwards.

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

**The structural rule is the only rule.** There is no way to override how a type is written out. An override would only make sense for a type whose literal form reconstructs something internally inconsistent — a cached field, an invariant the syntax does not restore — and nothing in the language creates that situation.

**A `type` value is written out as its type expression.** `int` reifies to `int`, `Array<int>` to `Array<int>`. That is what a static type parameter needs in order to be baked into a specialized copy, and it is why `Type` is the one record whose reified form is not its field structure. It stays total because `Type` is opaque for construction — every value of it came from a type that can be named.

**There is no size limit.** A compile-time value too large to write out produces a program too large to compile, and that is the author's problem.
