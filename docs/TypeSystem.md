# Type System

## Motivation

The primary use case driving these decisions is a **data + behavior file format** — a way to write files of objects with embedded functionality that can be edited without touching the underlying engine. Think game card databases, item definitions, configuration with logic. JSON solves the data side but has no answer for behavior. This language solves both.

The type system needs to support:
- Plain data objects that are trivial to write (no boilerplate)
- Functions as first-class values on objects
- A schema/interface layer the engine can declare and enforce
- Runtime loading of data files in the future (type checking at load boundaries)

---

## Primitives

```
int    string    bool    unit
```

---

## Object Types — Nominal Declarations, Structural Satisfaction

Types are declared nominally (they have a name and identity) but are satisfied structurally at data boundaries. Any object literal with the right shape satisfies a named type — the type name never needs to appear at the construction site.

```
type Person = {
    name: string,
    age: int
}

// Structural literal — satisfies Person without mentioning it
var p = { name: "Alice", age: 30 };

// Explicit typed assignment — p is coerced into Person
var p2: Person = p;
```

This keeps data files clean (no type names, just raw literals) while giving the engine a real nominal type system with identity.

---

## Function Types

Functions are first-class values and can appear as object fields.

```
type Card = {
    name: string,
    energy: int,
    apply: (int) -> int
}

var card = {
    name: "Card A",
    energy: 3,
    apply: (x) => { x * 2 }
}
```

Lambda syntax:
- `(x) => expr` — single expression, implicitly returned
- `(x) => { ... }` — block body, last expression implicitly returned
- `fn(...) { ... }` — named/multi-line form, explicit return

Function types in signatures: `(int) -> int`, `(string, int) -> bool`

---

## Default Fields

Named types can declare default values for fields. Defaults are a construction concern — the underlying type always includes the field, defaults are just sugar.

```
type Person = {
    name: string,
    age: int,
    gender: string = "girl"
}
```

Defaults are only applied when the expected type is known at the construction site (typed assignment or typed parameter). Without a known expected type, the literal's type is exactly what was written.

```
// expected type known — defaults applied, valid Person
var p: Person = { name: "Alice", age: 30 };

// no expected type — type is just { name: string, age: int }
var p = { name: "Alice", age: 30 };
```

---

## Constructor Coercion

An untyped object literal can be coerced into a named type at an explicit typed boundary, provided it contains all required fields. Missing fields with defaults are filled in automatically.

```
var p = { name: "Alice", age: 30 };
// type: { name: string, age: int }

var p2: Person = p;
// coerced — gender filled in with default "girl"
// p2 is now a full Person
```

Coercion rules:
- Only happens at explicit typed boundaries (typed assignment, typed function parameter)
- The object must have all required fields (those without defaults)
- Missing fields with defaults are filled in
- Extra fields are an error (not silently dropped)

This fits the data-file use case naturally — the data file writes raw literals, the engine declares the typed boundary, coercion and validation happen there.

---

## Mutability

Mutability is a property of the **binding**, not the type. `Card` is always just `Card` regardless of whether it is mutable.

```
var card = { ... }        // immutable binding
var mut card = { ... }    // mutable binding
```

References use Rust-inspired syntax for ergonomic clarity, but without a full borrow checker (no lifetime annotations, no exclusive borrow enforcement). The goal is **readable intent**, not memory safety enforcement.

```
fn inspect(card: &Card) { ... }    // borrows — no copy, read-only
fn process(card: Card) { ... }     // copies
```

`&` is part of the type (`&Card` vs `Card` — affects copying). `mut` is a binding property checked at call sites but not encoded in the type itself.

The simple rule the compiler enforces: **you cannot pass a non-`mut` binding to a function that takes `&mut`**.

---

## Type Inference

Bidirectional inference — the expected type flows inward. This means lambda parameters in data files don't need annotations:

```
type Card = {
    apply: (int) -> int
}

// x is inferred as int from the expected type of apply
var card: Card = {
    apply: (x) => { x * 2 }
}
```

At schema/interface boundaries, types are declared explicitly. Inside data literals, inference handles the rest.

---

## Enums — ADTs with Pattern Matching

Rust-style algebraic data types. Variants can be bare, tuple-style, or carry named fields. Syntax follows Rust closely — explicit braces, no significant whitespace.

**Simple enum**
```
enum Rarity {
    Common,
    Uncommon,
    Rare,
}
```

**ADT — variants carrying data**
```
enum CardEffect {
    Damage { amount: int },
    Heal { amount: int },
    Draw { count: int },
    None,
}
```

---

## Pattern Matching

`match` dispatches on an enum value. Each arm pairs a pattern with a block body; the first matching arm runs.

**Basic match**
```
match rarity {
    Rarity::Common   => { print("common");   }
    Rarity::Uncommon => { print("uncommon"); }
    Rarity::Rare     => { print("rare");     }
}
```

**Destructuring variant data**
```
match effect {
    CardEffect::Damage { amount } => { hp = hp - amount; }
    CardEffect::Heal   { amount } => { hp = hp + amount; }
    CardEffect::Draw   { count  } => { draw(count);      }
    CardEffect::None              => {}
}
```

**Tuple variant destructuring**
```
match shape {
    Shape::Point      => { print("point"); }
    Shape::Circle(r)  => { print(r);       }
    Shape::Rect(w, h) => { print(w + h);   }
}
```

**Wildcard**
```
match effect {
    CardEffect::Damage { amount } => { take_damage(amount); }
    _                             => {}
}
```

Planned: match as expression, exhaustiveness checking, guards, structural matching on records.

---

## Data File Pattern

The end goal — a `.cx` file that is pure data + behavior, editable without touching the engine:

```
// cards.cx
[
    {
        name: "Card A",
        energy: 3,
        rarity: Rare,
        apply: (x) => { x * 2 },
    },
    {
        name: "Card B",
        energy: 2,
        rarity: Uncommon,
        apply: (x) => { x + 4 },
    },
]
```

```
// engine
type Card = {
    name: string,
    energy: int,
    rarity: Rarity,
    apply: (int) -> int
}

var deck: [Card] = load("cards.cx");
// coercion + validation happens at this boundary
```
