# Path to 0.1.4

## Required Language Features

| # | Feature | Status | Test |
|---|---|---|---|
| 1 | Traits — declare method contracts, `impl Trait for Type` | ✅ Done | `tests/core/traits/basic_impl` |
| 2 | `impl` method calls via trait dispatch | ✅ Done | `tests/core/traits/multiple_impls` |
| 3 | Trait bounds on generic functions (`<T: Trait>`) | ✅ Done | `tests/core/traits/trait_bound` |
| 4 | Generic functions (`fn foo<T>(x)`) | ✅ Done | `tests/core/generics/generic_fn` |
| 5 | Generic structs (`struct Pair<A, B>`) | ✅ Done | `tests/core/generics/generic_struct` |
| 6 | Monomorphization of generic functions | ✅ Done | `tests/core/generics/monomorphize` |

---

## Feature Details

### 1 & 2. Traits and `impl`

A `trait` declares a named set of method signatures. An `impl` block provides a concrete implementation of that trait for a specific struct type. Methods are invoked with the regular dot-call syntax.

```cronyx
trait Describe {
    fn describe(self) -> string;
}

struct Circle {
    radius: int
}

impl Describe for Circle {
    fn describe(self) -> string {
        return "circle with radius " + self.radius;
    }
}

var c = Circle { radius: 5 };
print(c.describe());   // circle with radius 5
```

**Key rules:**

- `self` is the implicit receiver — its type is the struct being implemented.
- Every method listed in the `trait` block must be present in each `impl` block. A missing method is a compile error.
- Calling a trait method on a type that has no `impl` for that trait is a compile error.
- Multiple traits can be implemented for the same type; multiple types can implement the same trait.
- Trait methods and free functions share the same namespace — no ambiguity because trait methods are always called via dot syntax.

**Implementation notes:**

- New `MetaStmt::TraitDecl { name: String, methods: Vec<MethodSig> }` — where `MethodSig` holds the method name and parameter list (including `self`).
- New `MetaStmt::ImplDecl { trait_name: String, type_name: String, methods: Vec<FnDecl> }`.
- During type-checking, build a trait registry: `Map<(type_name, trait_name), Vec<FnDecl>>`.
- When type-checking a dot-call `val.method(args)`, resolve `val`'s concrete type, look up `method` in its trait impls, and type-check the call against the resolved signature.
- `self` in a method body is bound to the receiver's type at the call site.
- At the interpreter level, dot-calls on struct values check the impl registry before falling back to field access.

---

### 3. Trait Bounds

A generic function can require that its type parameter implements a specific trait. The bound is written `<T: Trait>` in the type parameter list.

```cronyx
trait Summary {
    fn summarize(self) -> string;
}

fn notify<T: Summary>(item: T) {
    print("Breaking news: " + item.summarize());
}
```

- Calling `notify` with a type that does not implement `Summary` is a compile error.
- Multiple bounds are written `<T: TraitA + TraitB>`.
- Bounds are checked at each call site during monomorphization (see §6).

**Implementation notes:**

- `TypeParam` in the AST carries an optional `Vec<String>` of bound names.
- During monomorphization, for each instantiation `notify(article)`, verify that the concrete type `Article` has impls for all bounds listed on `T`. Emit a descriptive error if not.

---

### 4. Generic Functions

A function can declare one or more type parameters between `<` and `>` after its name.

```cronyx
fn identity<T>(x) {
    return x;
}

fn first<T>(list) {
    return list[0];
}

fn swap<A, B>(pair) {
    return (pair.1, pair.0);
}
```

Type arguments are **inferred** at call sites — you never write `identity<int>(42)`, just `identity(42)`. The compiler infers `T = int` from the argument.

**Implementation notes:**

- The parser recognizes `fn name<T, U, ...>(params)` and collects type param names via `parse_type_params`. Bounds (`<T: Trait>`) are parsed and discarded — they serve as documentation only; no compile-time bound checking is enforced yet.
- `type_params: Vec<String>` is threaded through `MetaStmt::FnDecl` → `StagedStmt::FnDecl` → `RuntimeStmt::FnDecl`. Non-empty `type_params` marks the function as a monomorphization candidate.
- Type params are decorative on individual parameters (no `x: T` annotation enforcement). Monomorphization is driven by the inferred argument types at each call site.

---

### 5. Generic Structs

Struct declarations can take type parameters. Instances are created with the same `StructName { field: value }` syntax — the type arguments are inferred from the field values.

```cronyx
struct Pair<A, B> {
    first: A;
    second: B
}

struct Box<T> {
    value: T
}

var p = Pair { first: 1, second: "one" };   // Pair<int, string>
var b = Box  { value: [1, 2, 3] };          // Box<[int]>
```

- Field types can reference the type parameters of the enclosing struct.
- Two instantiations with different type arguments are distinct types at the type-checking level.

**Implementation notes:**

- The parser already strips `<A, B>` from `struct Pair<A, B>` — struct type params are discarded after parsing (same as they were before 0.1.4 for function params).
- Generic structs work at runtime because HM inference handles structural polymorphism — the interpreter doesn't distinguish `Pair<int, string>` from `Pair<bool, int>` at the value level.
- Struct monomorphization in `--dump-all` output (emitting a concrete `StructDecl` per instantiation) is **not yet implemented**. The struct name is not rewritten in the emitted code. This is left for a future pass.

---

### 6. Monomorphization

Generics are implemented by **monomorphization**: the compiler produces one concrete copy of each generic function or struct per unique set of type arguments used in the program. There are no runtime type tags or boxing — each copy is fully specialized.

```cronyx
fn wrap<T>(x) { return [x]; }

wrap(7);      // emits: fn wrap__int(x) { return [x]; }
wrap("hi");   // emits: fn wrap__string(x) { return [x]; }
```

After monomorphization `--dump-all` should show only the specialized copies; the original generic template is removed. The programmer never writes the mangled names.

**Why this matters beyond the interpreter:** HM inference makes the Cronyx interpreter handle polymorphic calls correctly today without specialization. But any future compiled backend (C, LLVM, Wasm) needs physically distinct functions per instantiation. Monomorphization also keeps `--dump-all` honest — the emitted code should be executable on a hypothetical backend that has no HM runtime.

**Implementation (`src/semantics/meta/monomorphize.rs`):**

1. `type_check_runtime` was changed to return `HashMap<usize, Type>` — the fully-substituted inferred type of every expression, collected during HM inference and available to the monomorphizer.

2. The monomorphization pass runs on `RuntimeAst` after type checking, before `compact()`:
   - Identifies all generic `FnDecl`s (non-empty `type_params`).
   - Walks all `Call` expressions; for each call to a generic function, looks up the inferred argument types and computes a mangle key by joining the type strings with `__` (e.g. `wrap__int`, `identity__str`).
   - For each unique `(fn_name, mangle_key)`, deep-clones the function body with fresh IDs under the mangled name.
   - Rewrites all call sites in-place to use mangled names.
   - Removes the original generic template from `stmts` and `sem_root_stmts`.

3. **Name mangling** uses `__` as the separator between the function name and type args. Double underscore is chosen because single underscore would be ambiguous with user-defined function names. Type strings: `int`, `str`, `bool`, `unit`; unresolved type vars become `t{N}`; tuples and lists produce `t{N}` until a dedicated type constructor is added to the type system.

**What's not done:** Struct monomorphization in `--dump-all` output — generic structs work at runtime via HM but their `StructDecl`s are not specialized in the emitted code.

---

## Design Notes

### Interaction with HM Inference

Cronyx already has parametric polymorphism via Hindley-Milner — `fn id(x) { return x; }` is already polymorphic without any annotation. Explicit `<T>` syntax layers on top:

- Without `<T>`: works today, implicitly polymorphic, no monomorphization.
- With `<T>`: marks the function as a monomorphization candidate. The compiler uses HM's inferred concrete types at each call site to drive specialization.

This means HM and monomorphization are complementary, not competing: HM provides the type inference that tells the monomorphizer what each instantiation's concrete types are. Monomorphization is a code-generation step that runs *after* type checking and uses the inferred type table as its input.

### `self` is Not Special

`self` in a method is just a named parameter with a known type (the implementing struct). There is no implicit `this` pointer or reference semantics — Cronyx is a value-oriented language. Mutation of `self` inside a method does not mutate the original binding at the call site (same as any other function parameter).

### No `dyn` / Dynamic Dispatch

There is no trait object / dynamic dispatch in 0.1.4. All trait resolution is static — every call site must have a concrete type known at compile time. A future release may add `dyn Trait` for runtime polymorphism.
