# Cronyx Language Reference

Cronyx is a statically-typed, expression-oriented scripting language. Source files use the `.cx` extension and are run with `cronyx main.cx`.

*Current version: 0.1.4*

---

## Types

| Type     | Examples                  |
| -------- | ------------------------- |
| `int`    | `0`, `42`, `-7`           |
| `bool`   | `true`, `false`           |
| `string` | `"hello"`, `"world"`      |
| `list`   | `[1, 2, 3]`, `["a", "b"]` |
| tuple    | `(1, "hi", true)`         |
| struct   | user-defined              |
| enum     | user-defined              |
| trait    | user-defined contract     |

---

## Variables

```cronyx
var x = 42;
var name = "Alice";
var flag = true;
var nums = [1, 2, 3];
```

Reassignment (no `var`):

```cronyx
x = 100;
name = "Bob";
```

Optional type annotation (parsed but not enforced beyond type checking):

```cronyx
var x: int = 42;
```

---

## Arithmetic

```cronyx
var a = 10 + 3;   // 13
var b = 10 - 3;   // 7
var c = 10 * 3;   // 30
var d = 10 / 3;   // 3  (integer division)
var e = -5;       // unary minus
```

String concatenation uses `+`:

```cronyx
var s = "Hello" + " " + "World";
```

---

## Comparison Operators

All return `bool`.

```cronyx
a == b
a != b
a < b
a > b
a <= b
a >= b
```

---

## Logical Operators

Use `&&`, `||`, and prefix `!`. Short-circuit evaluation applies.

```cronyx
if (x > 0 && x < 10) { ... }
if (flag || other)    { ... }
if (!flag)            { ... }
if (!arr[i])          { ... }   // ! applies after index operators
```

---

## Print

```cronyx
print(42);
print("hello");
print(x);
```

`print` accepts any value and outputs it followed by a newline.

---

## If / Else

```cronyx
if (x > 5) {
    print("big");
} else if (x == 5) {
    print("five");
} else {
    print("small");
}
```

Braces are required. Condition must be in parentheses.

---

## While Loop

```cronyx
var i = 0;
while (i < 5) {
    print(i);
    i++;
}
```

Compound assignment shorthands: `x += n`, `x -= n`, `x++`, `x--`.

---

## For Loop

**C-style** — `for (init; cond; incr)`:

```cronyx
for (var i = 0; i < 5; i++) {
    print(i);
}
```

`init` can be a `var` declaration or assignment. `incr` supports `i++`, `i--`, `i += n`, `i -= n`, or any assignment.

**For-each** — iterates over a list:

```cronyx
var names = ["alice", "bob", "charlie"];
for (name in names) {
    print(name);
}
```

---

## Functions

```cronyx
fn add(a, b) {
    return a + b;
}

print(add(3, 4));  // 7
```

Optional type annotations on parameters and implied return:

```cronyx
fn greet(name: string) {
    print("Hello " + name);
}

fn add(a: int, b: int) {
    return a + b;
}
```

Functions can be recursive:

```cronyx
fn fib(n) {
    if (n == 0) { return 1; }
    if (n == 1) { return 1; }
    return fib(n - 1) + fib(n - 2);
}
```

`return;` with no value exits a void function early.

---

## Lists

```cronyx
var xs = [1, 2, 3];
```

### Index Access

```cronyx
print(xs[0]);   // 1
print(xs[2]);   // 3
```

### Index Assignment

```cronyx
xs[0] = 99;
```

### 2D Lists (grids)

```cronyx
var grid = [[1, 2], [3, 4]];
print(grid[0][1]);   // 2
grid[1][0] = 99;
```

### List Methods

| Method             | Returns | Description                          |
| ------------------ | ------- | ------------------------------------ |
| `xs.len()`         | `int`   | Number of elements                   |
| `xs.push(val)`     | void    | Appends `val` in place               |
| `xs.pop()`         | element | Removes and returns the last element |
| `xs.contains(val)` | `bool`  | True if `val` is in the list         |

```cronyx
var xs = [1, 2, 3];
xs.push(4);
print(xs.len());       // 4
var last = xs.pop();   // 4
print(xs.contains(2)); // true
```

---

## Tuples

Create with parentheses, two or more elements. Access fields with `.0`, `.1`, etc.

```cronyx
var t = (10, "hello", true);
print(t.0);   // 10
print(t.1);   // hello
print(t.2);   // true
```

Functions can return tuples:

```cronyx
fn minmax(a, b) {
    if (a < b) { return (a, b); }
    return (b, a);
}

var pair = minmax(7, 3);
print(pair.0);   // 3
print(pair.1);   // 7
```

Negative values in tuple literals work as expected: `(0, -1)`.

---

## Strings

### Concatenation

```cronyx
var s = "Hello" + " " + "World";
```

### String Index Access

Returns a single-character `string` (there is no `char` type):

```cronyx
var s = "abc";
print(s[0]);   // "a"
```

### String Methods

| Method            | Returns        | Description                       |
| ----------------- | -------------- | --------------------------------- |
| `s.len()`         | `int`          | Number of Unicode characters      |
| `s.split(sep)`    | `list[string]` | Split on delimiter string         |
| `s.chars()`       | `list[string]` | List of single-character strings  |
| `s.trim()`        | `string`       | Strip leading/trailing whitespace |
| `s.contains(sub)` | `bool`         | True if `sub` is a substring      |

```cronyx
var s = "hello world";
print(s.len());            // 11
var parts = s.split(" ");
print(parts[0]);           // "hello"
print(parts[1]);           // "world"
var chars = "abc".chars();
print(chars[0]);           // "a"
print("  hi  ".trim());   // "hi"
if (s.contains("world")) { print("found"); }
```

---

## Structs

Define a struct with `struct`, access fields with `.`:

```cronyx
struct Point {
    x: int;
    y: int
}

var p = Point { x: 3, y: 4 };
print(p.x);   // 3
print(p.y);   // 4
```

Fields in the definition are separated by `;`. Fields in the literal are separated by `,`.

---

## Traits

A `trait` declares a named set of method signatures that a type must implement.

```cronyx
trait Describe {
    fn describe(self) -> string;
}
```

Method signatures use `self` as the receiver and may include a `-> ReturnType` annotation. The body is omitted — a trait only declares the contract.

---

## Impl

An `impl` block provides a concrete implementation of a trait for a specific struct type.

```cronyx
impl Describe for Circle {
    fn describe(self) -> string {
        return "circle with radius " + to_string(self.radius);
    }
}
```

- `self` inside a method refers to the receiver value. It is a regular parameter — mutating `self` does not affect the original binding at the call site.
- Multiple types can implement the same trait; a type can implement multiple traits.
- Methods are called with dot syntax: `c.describe()`.

```cronyx
trait Show {
    fn show(self) -> string;
}

struct Point {
    x: int;
    y: int
}

impl Show for Point {
    fn show(self) -> string {
        return "(" + to_string(self.x) + ", " + to_string(self.y) + ")";
    }
}

var p = Point { x: 3, y: 4 };
print(p.show());   // (3, 4)
```

---

## Generics

Functions can declare type parameters with `<T>`. The type arguments are always **inferred** at call sites — you never write `identity<int>(42)`.

```cronyx
fn identity<T>(x) {
    return x;
}

fn first<T>(list) {
    return list[0];
}

print(identity(42));        // 42
print(identity("hello"));   // hello
print(first([10, 20, 30])); // 10
```

Multiple type parameters:

```cronyx
fn swap<A, B>(pair) {
    return (pair.1, pair.0);
}

var result = swap((1, "hi"));
print(result.0);   // hi
print(result.1);   // 1
```

Struct declarations can also take type parameters (syntax only — fields accept any type):

```cronyx
struct Pair<A, B> {
    first: A;
    second: B
}

var p = Pair { first: 1, second: "one" };
print(p.first);    // 1
print(p.second);   // one
```

### Trait Bounds

A type parameter can be constrained to require a trait implementation using `<T: TraitName>`:

```cronyx
trait Summary {
    fn summarize(self) -> string;
}

fn notify<T: Summary>(item) {
    print("Breaking news: " + item.summarize());
}
```

Bounds are parsed and documented but not enforced at compile time in 0.1.4 — the call will fail at runtime if the method is missing.

### Monomorphization

The compiler produces one concrete copy of each generic function per unique set of argument types. The original generic template is removed from the output. Calling `wrap(7)` and `wrap("hi")` emits two distinct functions — `wrap__int` and `wrap__str` — internally. The programmer never writes or sees these names.

---

## Enums

Three variant kinds: unit, tuple, and struct.

### Unit Variants

```cronyx
enum Direction {
    North,
    South,
    East,
    West,
}

var d = Direction::North;
```

### Tuple Variants

```cronyx
enum Shape {
    Point,
    Circle(int),
    Rect(int, int),
}

var c = Shape::Circle(10);
var r = Shape::Rect(3, 4);
```

### Struct Variants

```cronyx
enum CardEffect {
    Damage { amount: int },
    Heal   { amount: int },
    None,
}

var e = CardEffect::Damage { amount: 15 };
```

---

## Match

Pattern-match on an enum value. Every arm requires braces.

```cronyx
match shape {
    Shape::Point         => { print("point"); }
    Shape::Circle(r)     => { print(r); }
    Shape::Rect(w, h)    => { print(w + h); }
}
```

Struct variant match:

```cronyx
match effect {
    CardEffect::Damage { amount } => { print(amount); }
    CardEffect::Heal   { amount } => { print(amount); }
    CardEffect::None              => { print("none"); }
}
```

Wildcard:

```cronyx
match x {
    Shape::Circle(r) => { print(r); }
    _                => { print("other"); }
}
```

---

## Imports

Only explicitly imported files are loaded. There is no automatic loading of sibling files.

### Qualified (module namespace)

```cronyx
import "helpers";

helpers.greet("World");
```

### Aliased

```cronyx
import "helpers" as h;

h.greet("World");
```

### Selective

```cronyx
import { greet, add } from "helpers";

greet("World");
```

### Wildcard (directory import)

Load every `.cx` file in a directory, each as its own qualified module:

```cronyx
import "utils/*";

print(math.add(2, 3));       // utils/math.cx → math module
print(strings.greet("World")); // utils/strings.cx → strings module
```

Only the `/*` glob is supported; nested wildcards are not.

Import paths are relative to the current file, without the `.cx` extension.

---

## Built-in Functions

### `print(value)`

Prints any value to stdout followed by a newline.

### `readfile(path)`

Reads a file at `path` (relative to the source file's directory) and returns its contents as a `string`.

```cronyx
var contents = readfile("data.txt");
print(contents.trim());
```

### `to_string(value)`

Converts any value to its string representation. Accepts `int`, `bool`, or `string`.

```cronyx
print(to_string(42));     // "42"
print(to_string(true));   // "true"
print(to_string(false));  // "false"
```

### `to_int(s)`

Parses a `string` as an integer.

```cronyx
var n = to_int("42");
print(n + 1);   // 43
```

---

## Operator Precedence (high to low)

| Level | Operators                                 |
| ----- | ----------------------------------------- |
| 1     | Postfix: `.field`, `.method(args)`, `[i]` |
| 2     | `!`, `-` (prefix unary)                   |
| 3     | `*`, `/`                                  |
| 4     | `+`, `-`                                  |
| 5     | `<`, `>`, `<=`, `>=`                      |
| 6     | `==`, `!=`                                |
| 7     | `&&`                                      |
| 8     | `\|\|` (lowest)                           |

Use parentheses to force evaluation order:

```cronyx
var result = (a + b) * c;
if (x > 0 && y > 0) { ... }   // no extra parens needed
```

---

## Complete Example: Fibonacci

```cronyx
fn fib(n) {
    if (n == 0) { return 1; }
    if (n == 1) { return 1; }
    return fib(n - 1) + fib(n - 2);
}

var i = 0;
while (i < 6) {
    print(fib(i));
    i = i + 1;
}
```

## Complete Example: List Processing

```cronyx
var words = ["apple", "banana", "cherry"];
var results = [];

for (w in words) {
    if (w.contains("a")) {
        results.push(w);
    }
}

print(results.len());
```

## Complete Example: Traits and Impl

```cronyx
trait Summary {
    fn summarize(self) -> string;
}

struct Article {
    title: string;
    author: string
}

struct Tweet {
    username: string;
    content: string
}

impl Summary for Article {
    fn summarize(self) -> string {
        return self.title + " by " + self.author;
    }
}

impl Summary for Tweet {
    fn summarize(self) -> string {
        return self.username + ": " + self.content;
    }
}

fn notify<T: Summary>(item) {
    print("Breaking news: " + item.summarize());
}

var a = Article { title: "Cronyx 0.1.4", author: "brendancron" };
var t = Tweet { username: "cronyx_lang", content: "traits are here" };

notify(a);   // Breaking news: Cronyx 0.1.4 by brendancron
notify(t);   // Breaking news: cronyx_lang: traits are here
```

---

## Complete Example: Enum + Match

```cronyx
enum Result {
    Ok(int),
    Err(string),
}

fn divide(a, b) {
    if (b == 0) {
        return Result::Err("division by zero");
    }
    return Result::Ok(a / b);
}

var r = divide(10, 2);

match r {
    Result::Ok(n)  => { print(n); }
    Result::Err(e) => { print(e); }
}
```

---

## What Is NOT Supported (as of 0.1.4)

- `and` / `or` keywords — use `&&` / `||`
- `break` / `continue` in loops
- `char` type — string indexing returns a single-char `string`
- Result/Option types — no built-in error handling
- `args()` built-in — planned for 0.2.0
- `std.io` module — use `readfile()` built-in for file I/O
- Trait bound enforcement — `<T: Trait>` is parsed but not checked at compile time
- Dynamic dispatch (`dyn Trait`) — all trait resolution is static
- Generic struct monomorphization in `--dump-all` output — generic structs work at runtime but their declarations are not specialized in the emitted code
