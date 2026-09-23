# Elaboration

`Resolve` runs after type checking and turns every construct whose meaning depends on a type — operators, compound assignment, indexing, literals — into a concrete call or a primitive, chosen once at compile time. It is the pass named in [Architecture](Architecture.md), and elaboration is the older word for what it does.

That is what lets a user-defined type give meaning to `+`, `==`, `[]`, and the rest without `int + int` costing anything more than it does today.

## An operator is a trait

Each operator is a trait the prelude declares, and a type gives the operator meaning by implementing it. The trait's associated `Output` is the result, so it need not be either operand:

```cronyx
type Vec2 {
    x: int,
    y: int
}

impl Add<Vec2> for Vec2 {
    type Output = Vec2;

    fn add(self, rhs: Vec2): Vec2 {
        return new Vec2 { x: self.x + rhs.x, y: self.y + rhs.y };
    }
}

var v = new Vec2 { x: 1, y: 2 } + new Vec2 { x: 3, y: 4 };

print(v.x);      // 4
print(v.y);      // 6
```

Selection is on both operands, not just the receiver, so the two sides may differ. The trait's argument is the right-hand type, which is what lets a scalar stand on the left:

```cronyx
impl Mul<Vec2> for int {
    type Output = Vec2;

    fn mul(self, rhs: Vec2): Vec2 {
        return new Vec2 { x: self * rhs.x, y: self * rhs.y };
    }
}

var doubled = 2 * v;

print(doubled.x);   // 8
```

That also means commutativity is not free. `v * 2` is `impl Mul<int> for Vec2`, a second impl, unless a rule derives it.

**`Eq` is the exception.** Both operands are the type and the answer is always a `bool`, so it takes no argument and binds no `Output`:

```cronyx
impl Eq for Vec2 {
    fn eq(self, rhs: Vec2): bool {
        return self.x == rhs.x && self.y == rhs.y;
    }
}

print(v == v);      // true
```

`!=` is not an impl of its own. A type that has said what equal means has said what unequal means, so `Resolve` lowers `a != b` as the negation of the `eq` call.

**`==` works on any two values of a type without an impl**, comparing them structurally. What `derive Eq for Vec2;` adds is the impl a `T: Eq` bound looks for, written by the compiler rather than by a deriver walking the shape.

## Bounds

Because operators are traits, generic code can require one, which is the thing a table of entries could not express:

```cronyx
fn twice<T: Add<T, Output = T>>(x: T): T {
    return x + x;
}

print(twice(21));      // 42
print(twice("ab"));    // abab
```

`Output = T` is an associated-type binding: it says what the impl the bound reaches must have bound, not merely that some impl exists. Without it the return type would be `T.Output` and could not be written as `T`.

The scalars implement the operator traits without a program declaring anything, so a bound reaches `int` as readily as a type that wrote an impl. Their impls emit a machine operation rather than a call — see [What it costs](#what-it-costs).

## Assignment and increment

`x += v` and `x++` always derive from the operator. `Resolve` rewrites the first as `x = x + v` and the second as `x = x + 1`, so a type needs only `Add` to get both:

```cronyx
var n = 1;

n += 2;          // n = n + 2
n++;             // n = n + 1
```

There is no in-place form. A `List` that wanted `xs += 4` to append rather than rebuild would need an `AddAssign` trait of its own, and `Resolve` would choose between the impl and the derivation — which is why `+=` is not rewritten in `Desugar`, where no type is known yet. Nothing declares one today.

## Indexing

Reading and writing an index are two traits, since a type may support one and not the other. `IndexSet` requires `Index`, so the element read and the element written cannot disagree:

```cronyx
type Ring<T> {
    items: Array<T>,
    head: int
}

impl Index<int> for Ring<T> {
    type Output = T;

    fn get(self, i: int): T {
        return self.items[(self.head + i) % self.items.len()];
    }
}

impl IndexSet<int> for Ring<T> {
    fn set(self, i: int, v: T): T {
        self.items[(self.head + i) % self.items.len()] = v;
        return v;
    }
}

print(ring[0]);
ring[0] = 5;
```

`xs[i] += 1` composes the two with the operator between them.

**A type that is not a container reads its element off the impl.** `Ring<T>` holds its elements in a field, so what indexing answers with comes from `Index`'s `Output` rather than from the type's own arguments — which is what associated types are for, and why a non-generic type can be indexed at all.

### Slicing is indexing by a range

`a[i:j]` is `a[r]` where `r` is a `Range`, so there is no slice operator — a type joins in by implementing `Index` once more, at `Range`:

```cronyx
impl Index<Range> for Ring {
    type Output = List<int>;

    fn get(self, r: Range): List<int> { return self.items[r]; }
}
```

Entries are keyed by **what indexes them**, which is what lets one type be read by an `int` and sliced by a `Range`. A type with a single entry answers for any index, so a container indexed by its own key type still works without naming that type twice.

One type implementing `Index` twice means two impls bringing a `get` apiece, so an impl's methods are named for the trait and its arguments rather than the type alone.

`Range` is a sum — `Between`, `From`, `To`, `All` — rather than a pair with sentinels, so `a[2:]` has no end bound rather than an end bound meaning *no*.

**A slice copies.** A view would have to say how long it lives, and nothing in the language does; a fresh collection has no aliasing to reason about.

**A bound counted from the end is the entry's business, not the language's.** `a[-1:]` works because the prelude's entries resolve a negative bound against `self.len()` — written once, inside the operator, where the length is known. `Desugar` could not do it: it does not know the receiver has a `len`. So a type opts in, and one that does not pays no test.

The prelude resolves negatives in a `Range` and not in a plain `[int]`: a bound is a position you are naming, an index is a lookup, and `a[-1]` from a computed expression is more often a mistake than an intention. `core/slices/negative_index` is the runtime case that pins it.

## Literals

A literal has no type of its own — it proposes candidates and the expected type picks one. That is the same table, keyed in the opposite direction: operators resolve forwards from operand types to a result, literals resolve backwards from a target type to a constructor.

```cronyx
var a: Array<int>       = [1, 2, 3];
var l: List<int>        = [1, 2, 3];
var s: Set<int>         = [1, 2, 3];
```

A type says it can be built from a literal by implementing `FromArray` — the array of elements the literal produces:

```cronyx
impl FromArray<T> for Ring<T> {
    fn from_array(items: Array<T>): Ring<T> {
        return new Ring { items: items, head: 0 };
    }
}
```

Building from a literal and reading an element are separate traits, though both are written `[…]`: one takes the elements and yields the container, the other takes the container and yields an element. The entry is identified by what it builds, so two containers over `Array<T>` do not collide.

See [Collection Literals](Collection%20Literals.md) for how that one works in detail. A numeric literal does not behave this way: `1` is an `int`, and `var x: float = 1;` is a type error rather than a widening.

String literals stay simple: a string literal is a `string`. Making them target-typed would attach a constraint to nearly every literal in a program, and it is deferred rather than decided.

## What it costs

Both of these lower during compilation, so nothing is looked up while the program runs:

```cronyx
var a = 1 + 2;                       // primitive add
var b = new Vec2 { x: 1, y: 2 } + v; // direct call to Vec2's `add`
```

The first emits the same node the evaluator has always handled. The second emits an ordinary call — the cost of the function you wrote, and nothing more.

## The table

An impl of an operator trait becomes an entry. The checker consults these for the result type, and the lowering pass for the emission:

```
(Add, int,    int)     → int      primitive add
(Add, float,  float)   → float    primitive add
(Add, string, string)  → string   primitive concat
(Add, Vec2,   Vec2)    → Vec2     call Vec2's `Add<Vec2>` impl
(Mul, int,    Vec2)    → Vec2     call int's `Mul<Vec2>` impl
```

Builtin arithmetic is not a special case in the compiler. It is an entry whose emission happens to be a primitive rather than a call, which is why `int + int` stays fast without the operator path knowing anything about it. The fast path is a resolution outcome, not something an optimizer recovers later.

Two consumers, one table — that is the reason for a table rather than two matches that have to agree.

## Inference

When operand types are not yet known, the checker attaches a constraint instead of resolving, exactly as it does today:

```cronyx
fn double(x) {
    return x + x;
}

print(typeof(double));   // (int) -> int
```

`x` is constrained to a type that has a `+`, nothing narrows it further, and an unresolved numeric variable defaults to `int`.

The same constraint is what a generic function carries. A body using `+` on a type parameter requires an entry for it, that requirement travels with the signature, and each call site discharges it against the table — inferred throughout, never written. See [Static Params](Static%20Params.md). Annotating changes the answer without changing the body:

```cronyx
fn double_vec(x: Vec2): Vec2 {
    return x + x;
}
```

## Polymorphism forces monomorphization

```cronyx
fn sum3(a, b, c) {
    return a + b + c;
}

print(sum3(1, 2, 3).x);            // int addition
print(sum3(v, v, v).x);            // Vec2 addition
```

One body, two answers. Either the function is specialized per instantiation — so each copy has concrete operand types and resolves statically — or the body dispatches at runtime, and the zero-cost property is lost precisely where generic code needs it.

So: resolve statically wherever types are concrete, and monomorphize generic functions so that they are. Monomorphization is already owed for `Generic` and for effect-polymorphic functions; this makes it load-bearing for a third feature rather than adding a new obligation.

Without it, zero-cost operators exist only in monomorphic code. That is the ceiling, and it is worth stating rather than discovering.

A trait written as a type is the one place a call is not resolved to a name, and it does not weaken any of this: the table it dispatches through holds the same plain functions an impl flattens to, built once at compile time. What a call site does not know is which table the value carries — see [Static vs Dynamic Invocation](Static%20vs%20Dynamic%20Invocation.md).

## Rules the table needs

- **Precedence** when two entries match the same operands.
- **A designated default**, so an unresolved numeric literal has an answer.
- **Which operators are open.** `&&` and `||` short-circuit, so overloading them would be overloading control flow — they stay closed:

  There is no `And` trait to implement, and `&&` is its own node rather than a call.

- **Registration completes before type checking**, since the checker consults the table.

## Methods are not in the table

`xs.len()` looks like it belongs here, and it does not. An operator is selected from the types of its operands, which is why no name the author writes appears in the lowered code; a method is named at the call site, and the only question is which type's version of that name is meant. That is a lookup keyed by `(type, method)`, not a search over operand types, so it is a separate table with a separate rule.

```cronyx
trait Len {
    fn len(self): int;
}

impl Len for Array {
    fn len(self): int { … }
}

impl Rectangle {
    fn area(self): int { return self.width * self.height; }
}
```

An `impl` without a trait gives the methods to the type alone; naming a trait additionally claims to satisfy it, and every signature the trait declares must be supplied. Each method compiles to a function under a derived name, taking the receiver first — `Rectangle__area(r)` — so nothing downstream of [Resolve] has a notion of a method at all.

Dispatch needs the receiver's type where the call is written. A receiver whose type is still a variable has no answer, which is the same wall [`Polymorphism forces monomorphization`](#polymorphism-forces-monomorphization) describes for operators, and it lifts at the same time.

## What this replaces

The previous approach dispatched at runtime: a `HashMap` keyed by `(trait, type_name)`, consulted on every evaluation of an operator whose left operand was a struct, and reached only after falling through a match on the builtin cases. Selection here happens once, at compile time, and the builtin cases are entries rather than a fallthrough.

## Two lookups, one registry

Operators and literals are keyed in opposite directions — an operator lookup takes operand types and yields a result, a literal lookup takes a target type and yields a constructor — so they are two maps rather than one with a discriminant and unused fields.

They are built and passed together as a single registry, so registration and injection stay one thing even though the lookups are two.

## Settled

**`v * 2` is not derived from `2 * v`.** Both are written, or neither works. A derivation rule would silently invent an entry the author did not write, and commutativity is not a property the compiler can assume of a user's operator.
