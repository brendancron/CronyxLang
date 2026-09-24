# Static params

A `<>` list declares parameters known at compile time. Monomorphization emits one copy of the function per distinct set of arguments, with those arguments baked in — so a static parameter costs nothing at runtime.

Two passes make the copies. A function taking a static *value*, or one whose body runs a `meta` block, is instantiated by the metaprocessing walk when a call to it is reached, before anything is checked, because a value can decide what the body is. A function taking only types, and running no `meta`, is checked once generically and copied by `Type_mono` afterwards, because inference is what says which types it is used at. See [Metaprocessing](Metaprocessing.md#templates).

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
fn buffer<T, n: int>(fill: T): Array<T> {
    return new Array<T>(n, fill);
}

var b = buffer<int, 16>(0);
```

This is where value parameters earn their place: a static `int` used as an array size is const generics, without const generics being a separate feature. If `[T; N]` is ever wanted, it is a use of this mechanism rather than a new one.

## Types that take values

A type takes value parameters the same way, and each argument list is a type of its own:

```cronyx
type Buf<n: int> {
    items: Array<int>,
}

var a = new Buf<4> { items: [] };
a = new Buf<8> { items: [] };      // Expected Buf<4>, got Buf<8>.
```

A copy is named by its arguments, `Buf<4>`, and is made when `new Buf<4> { … }` is reached (`meta/05_order/11_buf`, `errors/distinct_instances`). A value argument in a type annotation — `var b: Buf<4>` — does not parse yet.

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

**Value parameters check twice**, because a value can decide a type:

```cronyx
fn f<n: int>(): int {
    meta if (n % 2 == 0) { gen return 5; } else { gen return "hello"; }
}
```

There is no single type for that body — it depends on the *value* of `n`. So it is checked the way C++ checks a template. Before metaprocessing, `Precheck` checks every body, called or not, with a value parameter as a local of its declared type and what a `meta` block produces unknown; that reports whatever is wrong for every value at the definition — `fn label<a: int>(b: string): string { return a + b; }` is an error though nothing calls it (`meta/07_precheck/errors/unreached_value_param`). After the walk, each instantiation it made is checked in full, and what depends on the value surfaces there: `f<2>` is fine, `f<3>` is *Expected int, got string.* (`meta/07_precheck/errors/instance_mismatch`). See [Type System](Type%20System.md#checked-twice-before-metaprocessing-and-after).

That is two checking regimes in one language. The alternative is restricting value parameters so they cannot influence types, which keeps a single regime and removes the reason to have them.

## What may appear in `<>`

At a call site, a value argument is an expression the compiler can evaluate: literals and the static parameters of the enclosing function, under the operators, folded where the call stands. `f<2 + 3>()` is the copy `f<5>()` is, and `fn g<k: int>() { f<k + 1>(); }` asks for `f<k + 1>` with `k` already written in (`meta/05_order/28_const_args`). A call is not evaluated there — that is a `meta` block's job, and what one computes reaches a static argument through a `gen`, which writes it back as a literal: `gen f<a - 1>()` emits `f<1>()` (`meta/05_order/19_gen_static_arg`). Arithmetic parses in `<>` at additive precedence, so the closing `>` is never read as an operator.

The rule is "evaluable by the compiler" rather than "a literal" so that it stays the same rule when there is more for the compiler to evaluate — a static variable, say.

```cronyx
fn wrap<prefix: string>(x: int): string {
    return prefix + str(x);
}

fn outer<tag: string>(x: int): string {
    return wrap<tag>(x);          // fine: tag is static here
}

var n = read_int();
wrap<n>(1);                       // rejected: n is a run-time variable
wrap<str(1)>(1);                  // rejected: a call is evaluated only in a meta block
```

The diagnostic says *why* an expression is not static, not merely that it is not: *'n' is not known at compile time: it is a run-time variable, not a static parameter of the enclosing function.*, and *This argument to 'wrap' is not known at compile time: a call is evaluated at compile time only inside a meta block.*

Inside a `meta` block the question is asked from the other side. A static parameter is an ordinary value there, so `fib<n - 1>()` written in the block and not in a `gen` is *'fib' cannot be instantiated from inside a meta block: 'n' is a value there. Write the call inside a gen.* — see [Meta Scope and Instantiation](Meta%20Scope%20and%20Instantiation.md).

A **type** argument to a function the walk instantiates is written, or visible from what the walk can see — `new X`, an annotation, a literal, a declared return type. Inference has not run when the walk reaches the call, so `printSpeak<Cat>(cat)` is how a template whose `meta` reads its type parameter is called (`meta/05_order/07_type_mono`). A type-only template the walk leaves alone keeps full inference.

## Templates in a body

A function with value parameters declared inside another function is instantiated like one at the top level, so it is lifted there under its owner's name. It may read only what it is passed: a copy of it lives wherever the walk puts it, away from the body that declared it.

## Specialization

One copy per distinct argument set, so the compiler needs a canonical key for static values and equality on them. Two consequences:

- **Code size grows with distinct arguments.** `logged<"a">` and `logged<"b">` are separate functions. This is the known cost of the approach.
- **Effect rows belong in the key.** A static function argument that performs effects changes the body's row, so two instantiations differing only in the effects of an argument are genuinely different functions.

## Interactions

**Operators.** An operator inside a generic body cannot be resolved until the body is concrete, so monomorphization is what makes operator selection static. Without it, generic code that uses `+` has to dispatch at runtime.

**Collection literals.** Same shape: a literal in a generic body has an element type that is only known per instantiation.

**Reflection.** `typeof(x)` is asked a question where it stands — `.name`, `.shape` or `.attrs` — rather than handed around, so a type does not travel into a `<>` list as a value. A type argument is written by name, and a `meta` block reads one with `typeof(T)`.

## Writing a type argument, and reading a type

A type parameter is inferred from the call, and may also be written out when inference has nothing to go on — the way Kotlin treats them:

```cronyx
var xs = pair(1, 2);          // T inferred
var ys = pair<int>(1, 2);     // T written
var empty = pair<string>();   // nothing to infer from
```

Writing them explicitly collides with comparison: `pair<int>(1, 2)` and `a < b` are the same shape, and `a<b` without spaces is idiomatic, so whitespace cannot decide it. The rule is C#'s, narrowed — after an identifier, try to parse a type argument list, and accept it only if the token after the closing `>` is `(`. Explicit arguments appear only at call sites and after `new`, which says a type follows, so requiring the call to follow is sufficient, and the one program it misreads — `a < b > (c)` — is not one anybody writes.

This is the same ambiguity that moved effect rows before the return type, and it is worth noting that the fix there does not help here. In type position `<` is never comparison; in expression position it is.

A type is not a value. `typeof(x)` answers `.name`, a string; `.shape`, a `TypeShape` from the prelude; and `.attrs`. Holding the `Type` itself is *A type is not a value here.* The shape is what makes structural metaprogramming possible — walking a product's fields, or a sum's variants, without the compiler exposing a bespoke API for each:

```cronyx
type TypeShape {
    Scalar,
    Product(Name, Array<TypeField>),
    Sum(Name, Array<TypeVariant>),
    Other,
}

type TypeField   { name: Name, attrs: Array<Attr> }
type TypeVariant { name: Name, arity: int, attrs: Array<Attr> }
```

A product and a sum carry a `Name` because a declaration is where a name that can be spliced exists; the other shapes have none. Nothing constructs a type programmatically, so nothing reified could name a type that does not exist. A field reporting its own type waits on a lazy handle for one.

## Settled

**No defaults on static parameters.** Every one is supplied at the call site. Adding defaults later is additive — a parameter that gains one keeps working for callers that already pass it.
