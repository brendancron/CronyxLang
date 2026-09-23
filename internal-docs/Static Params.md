# Static params

A `<>` list declares parameters known at compile time. Monomorphization emits one copy of the function per distinct set of arguments, with those arguments baked in — so a static parameter costs nothing at runtime.

Other languages call this generics, but here the arguments are values, and a type is only the most common kind of value.

## Types

A bare name is a type parameter, inferred from the call:

```cronyx
fn pair<T>(a: T, b: T): Array<T> {
    return [a, b];
}

var xs = pair(1, 2);          // T = int
var ys = pair("a", "b");      // T = string
```

## Values

An annotated name is a value parameter, passed explicitly — a string cannot be recovered from the types of the arguments:

```cronyx
fn logged<label: string>(x: int): int {
    print(label + ": " + str(x));
    return x;
}

logged<"count">(3);           // prints "count: 3"
```

The specialized copy has no `label` parameter. The string is part of the code.

## Both

```cronyx
fn buffer<T, n: int>(): Array<T> {
    return new Array<T>(n);
}

var b = buffer<int, 16>();
```

This is where value parameters earn their place: a static `int` used as an array size is const generics, without const generics being a separate feature. If `[T; N]` is ever wanted, it is a use of this mechanism rather than a new one.

## Checking

Type parameters and value parameters are checked differently, and the `<>` list says which applies.

**Type parameters check once.** The body is checked generically, exactly as let-polymorphism already does, and an error in it is reported at the definition.

What the body requires of a type parameter is *inferred*, not written:

```cronyx
fn sum<T>(xs: Array<T>): T {
    var total = xs[0];
    for (x in xs) { total = total + x; }
    return total;
}
```

The `+` means `sum` requires an entry for `(Add, T, T)`, so its signature carries that requirement:

```
sum : (Array<T>) -> T   where (Add, T, T) -> T
```

This is the mechanism already in the checker. `fn double(x) { return x + x; }` infers that `x` is addable because the body used `+`; a type parameter accumulates requirements the same way, from a set of entries rather than a fixed lattice of kinds.

Errors land in the two places you would want them:

- **Using `T` in a way no entry could satisfy** is an error at the definition, because the body is checked once.
- **Instantiating with a type that has no such entry** — `sum` on an `Array<Vec3>` where `Vec3` has no `Add` impl — is an error at the call site, naming the requirement and where it came from.

There is deliberately no way to *write* a constraint. `T: Add` would name a predicate over the operator table as though it were something declarable, and nothing declares it — the entries are what exist. See [Elaboration](Elaboration.md).

**Value parameters check per instantiation**, because a value can decide a type:

```cronyx
fn field_of<name: string>(r) {
    return r.name;
}
```

There is no single type for that body — it depends on the *value* of `name`. So the value is substituted first and the resulting body is checked, once per distinct argument. Errors in such a body surface at the call site rather than the definition, which is the price of the feature.

That is two checking regimes in one language. The alternative is restricting value parameters so they cannot influence types, which keeps a single regime and removes the reason to have them.

## What may appear in `<>`

At a call site, an argument must be known at compile time: a literal, another static parameter in scope, or a call to something evaluable at compile time.

```cronyx
fn wrap<prefix: string>(x: int): string {
    return prefix + str(x);
}

fn outer<tag: string>(x: int): string {
    return wrap<tag>(x);          // fine: tag is static here
}

var n = read_int();
wrap<str(n)>(1);                  // rejected: n is not known at compile time
```

The diagnostic needs to say *why* an expression is not static, not merely that it is not.

## Specialization

One copy per distinct argument set, so the compiler needs a canonical key for static values and equality on them. Two consequences:

- **Code size grows with distinct arguments.** `logged<"a">` and `logged<"b">` are separate functions. This is the known cost of the approach.
- **Effect rows belong in the key.** A static function argument that performs effects changes the body's row, so two instantiations differing only in the effects of an argument are genuinely different functions.

## Interactions

**Operators.** An operator inside a generic body cannot be resolved until the body is concrete, so monomorphization is what makes operator selection static. Without it, generic code that uses `+` has to dispatch at runtime.

**Collection literals.** Same shape: a literal in a generic body has an element type that is only known per instantiation.

**Reflection.** With types as static values, `typeof(x)` returning a `type` is more useful than returning a `string`, since the result can be passed straight into a `<>` list. The string form becomes `name_of(typeof(x))`. Worth deciding before fixtures pin the current string behavior.

## `type` as a value

A type parameter is inferred from the call, and may also be written out when inference has nothing to go on — the way Kotlin treats them:

```cronyx
var xs = pair(1, 2);          // T inferred
var ys = pair<int>(1, 2);     // T written
var empty = pair<string>();   // nothing to infer from
```

Writing them explicitly collides with comparison: `pair<int>(1, 2)` and `a < b` are the same shape, and `a<b` without spaces is idiomatic, so whitespace cannot decide it. The rule is C#'s, narrowed — after an identifier, try to parse a type argument list, and accept it only if the token after the closing `>` is `(`. Explicit arguments appear only at call sites, so requiring the call to follow is sufficient, and the one program it misreads — `a < b > (c)` — is not one anybody writes.

This is the same ambiguity that moved effect rows before the return type, and it is worth noting that the fix there does not help here. In type position `<` is never comparison; in expression position it is.

A type name in expression position *is* the value, so `int` and `Array<int>` are ordinary expressions of type `Type`. `typeof` yields one, and reification writes one back out as the type expression that denotes it.

`Type` is a record like any other, so field access and reification come from the record rules:

```cronyx
type Type {
    name: string,
    shape: Shape
}

type Shape {
    Scalar,
    Array(Type),
    List(Type),
    Tuple([Type]),
    Record([Field]),
    Named([Field]),
    Sum([Variant]),
    Fn { params: [Type], ret: Type, effects: [string] }
}

type Field   { name: string, ty: Type }
type Variant { name: string, payload: [Type] }
```

`name` is what `derive` already uses. `shape` is what makes structural metaprogramming possible — walking a record's fields, or a sum's variants, without the compiler exposing a bespoke API for each.

**`Type` is opaque for construction.** Its fields can be read, but a value is only obtained from `typeof` or from writing a type expression — there is no `new Type { … }`. A constructed one would correspond to no actual type and would have no type expression to reify back to, so forbidding it keeps reification total. Creating types programmatically is deferred.

## Settled

**No defaults on static parameters.** Every one is supplied at the call site. Adding defaults later is additive — a parameter that gains one keeps working for callers that already pass it.
