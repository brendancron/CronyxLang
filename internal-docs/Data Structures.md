# Data structures

The datatypes the language has, and what each looks like in use.

Two of these are primitive: `Array` is a contiguous mutable block and `string` is a sequence of characters, and neither can be written in Cronyx because nothing in Cronyx can see inside them. Everything else is a declared type. `List`, `Set` and `Map` are written in the prelude, in Cronyx, with no compiler support of any kind — what makes a type a container is a declaration saying how to build one from a literal and whether it can be indexed, and any program can write one.

The primitives are as small as they can be. Their operations that *are* expressible — `Array.contains`, `string.split`, `string.trim` — are prelude code like any other method.

## Array

`Array<T>` — length fixed at creation. Elements can be reassigned; the array cannot grow.

```cronyx
var xs = [1, 2, 3];

xs[0] = 5;

print(xs[0]);            // 5
print(xs.len());         // 3
print(typeof(xs));       // Array<int>
```

An array has identity: a second name is the same array, not a copy, and writing through one is visible through the other. `==` asks whether two values are structurally equal, so `[1, 2] == [1, 2]` is true; `same(xs, ys)` asks whether they are the same array. For a scalar there is nothing to tell apart, so `same` and `==` agree.

An array of a given size:

```cronyx
var zeros = new Array<int>(16);

print(zeros.len());      // 16
print(zeros[0]);         // 0
```

## String

`string` — a sequence of Unicode scalar values. `len` and indexing count characters, not bytes, and both are constant time.

```cronyx
var s = "héllo";

print(s.len());          // 5
print(s[1]);             // é
print(typeof(s[1]));     // char
print(s.contains("éll"));// true
print("a,b".split(','));  // [a, b]
```

A string cannot be written through — `s[0] = c` is an error — so an index reads and nothing writes.

## Char and byte

`char` is one scalar value, written `'é'`, with the escapes a string literal takes: `\n`, `\t`, `\r`, `\0`, `\\`, `\'`, `\"`. `byte` is one octet and has no literal, so it is reached by asking a string for its encoding.

```cronyx
print(s.chars().len());  // 5   Array<char>
print(s.bytes().len());  // 6   Array<byte>, the UTF-8 encoding
```

`chars` copies, because an array is mutable and a string is not. `bytes` is the wire form: it is what leaves the process, and the only string operation the compiler still supplies.

These are code points, not grapheme clusters. `é` written as `e` plus a combining accent is two characters, the same answer Python gives and a different one from Swift.

## List

`List<T>` — grows, backed by an array.

```cronyx
var xs: List<int> = [1, 2, 3];
xs.push(4);

print(xs[0]);            // 1
print(xs.len());         // 4
print(typeof(xs));       // List<int>
```

An empty collection is written `[]`, and states its type where there is nothing to infer one from:

```cronyx
var results: List<int> = [];

results.push(3);
```

## Collection literals

`[1, 2, 3]` does not commit to a container. An annotation, a parameter type, or a method call decides which one it builds, and with nothing to narrow it the literal is an array.

```cronyx
var a: Array<int> = [1, 2, 3];
var l: List<int>  = [1, 2, 3];
var s: Set<int>   = [1, 2, 3];
var d             = [1, 2, 3];   // Array<int>
```

See [Collection Literals](Collection%20Literals.md) for the rules.

## Tuple

`(A, B, ...)` — fixed length, positional, mixed types.

```cronyx
var pair = (1, "hello");
var nested = ((1, 2), "abc");

print(typeof(pair));     // (int, string)
print(typeof(nested));   // ((int, int), string)
```
## Type declarations

One keyword declares both products and sums. The body says which: entries written `name: T` are fields, bare entries are variants. A declaration may not mix the two.

A product is a named record — nominal, so two declarations with identical fields are still different types.

```cronyx
type Point {
    x: int,
    y: int, // trailing comma is optional
}

var p = new Point { x: 1, y: 2 };

print(p.x);              // 1
print(typeof(p));        // Point
```

A sum lists its variants. They carry nothing, a tuple of values, or fields.

```cronyx
type Color { Blue, Red, Green }

type Shape {
    Circle(int),
    Rect { w: int, h: int },
    Empty
}

var s = Shape::Rect { w: 3, h: 4 };

match s {
    Shape::Circle(r)     => { print(r); }
    Shape::Rect { w, h } => { print(w * h); }   // 12
    Shape::Empty         => { print("empty"); }
}
```

Both take type parameters.

```cronyx
type Option<T> { Some(T), None }

type Pair<A, B> {
    first: A,
    second: B
}

var found = Option::Some(3);
var both = new Pair { first: 1, second: "one" };
```

## Map

`Map<K, V>` — a collection literal reads as a map when the annotation says so, taking the last value written for a key.

```cronyx
var ages: Map<string, int> = [("alice", 30), ("bob", 25)];

ages.insert("carol", 41);

print(ages.len());                  // 3
print(ages.contains("alice"));      // true
print(ages.get_or("bob", 0));       // 25
print(ages.get_or("dave", -1));     // -1
```

A map's element type is the pair `(K, V)`, so an array of tuples is already the right shape and no separate literal form is needed. That is not a special case: the impl declares it, as `impl FromArray<(K, V)> for Map<K, V>`.

There is no `get` returning an `Option`, because there is no `Option` — what a lookup does when a key is absent is part of a fallibility design that has not been settled, and `get_or` is what can be written without settling it. Lookup is a linear scan comparing keys with `==`, so a record key is matched on its fields.

## Set

`Set<T>` — a collection literal reads as a set when the annotation says so, dropping duplicates.

```cronyx
var seen: Set<int> = [1, 2, 2, 3];

seen.insert(4);

print(seen.contains(2));    // true
print(seen.len());          // 4
```

A set declares a literal and no indexing, so `seen[0]` is an error. The three bracket entries are independent and a type takes only the ones that mean something for it.

Membership is `==`, which is structural — two records with equal fields are the same element, and a set of them holds one. Identity, when that is the question being asked, is `same(a, b)`.
