Cronyx uses Hindley-Milner type inference — types are inferred automatically, with optional annotations available for documentation and constraint. The type checker runs in two phases: once before meta-processing on the full source AST, and once after meta-processing on the final runtime AST.

---

## Primitive Types

```
int     bool     string     unit
```

`unit` is the type of expressions that produce no meaningful value (void functions, side-effecting statements).

---

## Compound Types

### Functions

Functions are first-class values. A function that takes one `int` and returns a `string` has the type:

```
(int) -> string
```

Multi-parameter:

```
(int, bool) -> int
```

### Records

Object literals have record types — a set of named fields with inferred types:

```
var p = { name: "Alice", age: 30 };
// type: { age: int, name: string }
```

Field names are sorted alphabetically in the type representation.

### Lists

Lists are homogeneous. All elements must share a type, inferred from the contents:

```
var xs = [1, 2, 3];
// type: [int]
```

### Tuples

Tuples are fixed-length, heterogeneous groupings of values. Unlike records, fields are positional rather than named.

```
var pair = (1, "hello");
// type: (int, string)

var triple = (true, 42, "done");
// type: (bool, int, string)
```

Fields are accessed by index using dot notation:

```
var x = pair.0;   // 1    : int
var y = pair.1;   // "hello" : string
```

Tuples are most useful as lightweight return types and as payloads in enum variants.

### Enums

Enums are nominal sum types — a value of an enum type is exactly one of its declared variants. Variants can carry no data, a positional tuple of fields, or a set of named fields.

```
// Unit variants — no payload
enum Direction {
    North,
    South,
    East,
    West,
}

// Tuple variants — positional payload
enum Shape {
    Point,
    Circle(float),
    Rect(float, float),
}

// Struct variants — named payload
enum CardEffect {
    Damage { amount: int },
    Heal   { amount: int },
    Draw   { count: int },
    None,
}
```

An enum can mix all three variant forms freely.

**Constructing enum values:**

```
var dir  = Direction::South;
var circ = Shape::Circle(3.14);
var dmg  = CardEffect::Damage { amount: 10 };
```

**Enum types are nominal.** Two enums with identical variants are still distinct types. The constructor syntax `Enum::Variant` makes the enum name explicit at every construction site.

---

## Type Annotations

Type annotations are optional. When present, they act as constraints that the inferred type must satisfy — a mismatch is a `TypeMismatch` error.

### Variable annotations

```
var x: int = 5;
var name: string = "Alice";
var flag: bool = true;
```

### Parameter annotations

```
fn add(a: int, b: int) {
    return a + b;
}

fn greet(name: string) {
    print("Hello " + name);
}
```

Annotations can be mixed freely with unannotated parameters:

```
fn wrap(prefix: string, suffix) {
    return prefix + suffix;
}
```

The four annotatable primitive types are `int`, `bool`, `string`, and `unit`. Annotations on unknown type names are silently ignored (treated as unannotated).

**No return type annotations** — return types are always inferred from `return` statements.

---

## Type Inference

Cronyx uses Algorithm W (Hindley-Milner) to infer types. Annotations are not required — the type checker propagates constraints through the AST and resolves them via unification.

### Unification

When two types must be equal, the type checker unifies them. This either succeeds (possibly refining type variables) or fails with a `TypeMismatch` error.

```
fn add(a, b) { return a + b; }
add(1, 2);
// a and b are unified with int
// add : (int, int) -> int
```

### Generalization and Polymorphism

Functions are generalized at their definition site. A function whose parameters are unconstrained becomes polymorphic — each call site gets a fresh copy of the type, so the same function can be used with different types:

```
fn id(x) { return x; }

var a = id(1);     // a : int
var b = id(true);  // b : bool
```

Internally, `id` is given the polymorphic type `∀'a. ('a) -> 'a`. Each call instantiates `'a` freshly.

### Add is Polymorphic

The `+` operator works on both `int` and `string`. The type checker unifies both operands to a single type variable, so mismatched operands are caught:

```
1 + 2;         // int + int → int
"a" + "b";     // string + string → string
1 + "a";       // TypeMismatch error
```

---

## Function Declarations

Functions can be called before their declaration in the same scope — the type checker hoists all function types before checking call sites.

Return type is inferred from `return` statements. A function with no `return` has return type `unit`.

```
fn fib(n) {
    if (n == 0) { return 1; }
    if (n == 1) { return 1; }
    return fib(n-1) + fib(n-2);
}
// fib : (int) -> int
```

Inconsistent return types across branches are an error:

```
fn bad() {
    if (true) { return 1; }
    else      { return "oops"; }  // TypeMismatch: int vs string
}
```

---

## Two-Phase Type Checking

Cronyx's meta-programming system requires two separate type-checking passes.

### Phase 1 — MetaAst (Permissive)

The first pass runs on the AST before meta-processing. At this stage, names introduced by `meta {}` blocks do not yet exist. Phase 1 is intentionally permissive: an unbound variable gets a fresh type variable rather than an error. This allows meta-generated names to appear in the source without causing spurious errors.

Phase 1 still catches structural errors: type mismatches, wrong argument counts, inconsistent return types.

### Phase 2 — RuntimeAst (Strict)

The second pass runs after meta-processing, on the final runtime AST. By this point all meta-generated code has been inlined. Phase 2 is strict — an unbound variable is a hard error.

Phase 2 checks every tree processed by the meta interpreter (mini-trees for meta blocks and meta functions) as well as the root program. A shared type environment accumulates names across mini-trees: a function declared with `meta fn` in one tree is visible when type-checking a later meta block that calls it.

```
meta fn tag(name) {
    gen { print(name); }
}
// 'tag' is now in the Phase 2 TypeEnv

meta {
    tag("hello");  // Phase 2 checks this against tag's type
}
```

---

## Type Errors

| Error | Cause |
|---|---|
| `TypeMismatch { expected, found }` | Two types that should be equal cannot be unified |
| `UnboundVar(name)` | Variable referenced but not in scope (Phase 2 only) |
| `InvalidReturn` | `return` used outside a function body |

---

## Modules

Imported module namespaces are given a fresh type variable. Member types within modules are not tracked — dot-access (`util.foo`) and dot-calls (`util.bar(x)`) are accepted without checking the member against a known module type.

---

## Current Limitations

- **No enums or ADTs**: Sum types and pattern matching are not yet implemented.
- **No module member types**: Imported namespaces are opaque to the type checker.
- **No lambda syntax**: Anonymous functions are not yet supported.
- **Struct fields are unchecked**: Record literals are typed structurally by their fields; struct declarations exist in the AST but field access is not type-checked against a declared schema.
