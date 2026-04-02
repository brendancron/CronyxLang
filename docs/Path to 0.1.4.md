# Path to 0.1.4

## Required Language Features

| # | Feature | Status | Test |
|---|---|---|---|
| 1 | Traits — declare method contracts, `impl Trait for Type` | ⬜ Pending | `tests/core/traits/basic_impl` |
| 2 | `impl` method calls via trait dispatch | ⬜ Pending | `tests/core/traits/multiple_impls` |
| 3 | Trait bounds on generic functions (`<T: Trait>`) | ⬜ Pending | `tests/core/traits/trait_bound` |
| 4 | Generic functions (`fn foo<T>(x: T) -> T`) | ⬜ Pending | `tests/core/generics/generic_fn` |
| 5 | Generic structs (`struct Pair<A, B>`) | ⬜ Pending | `tests/core/generics/generic_struct` |
| 6 | Monomorphization — one concrete copy per instantiated type | ⬜ Pending | `tests/core/generics/monomorphize` |

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

A function can declare one or more type parameters between `<` and `>` after its name. Type parameters can appear anywhere a type can appear: parameter types, return type, and local variable annotations.

```cronyx
fn identity<T>(x: T) -> T {
    return x;
}

fn first<T>(list: [T]) -> T {
    return list[0];
}

fn swap<A, B>(pair: (A, B)) -> (B, A) {
    return (pair.1, pair.0);
}
```

Type arguments are **inferred** at call sites — you never write `identity<int>(42)`, just `identity(42)`. The compiler infers `T = int` from the argument.

**Implementation notes:**

- The parser recognizes `fn name<T, U, ...>(params)` — collects type param names and stores them on `FnDecl`.
- During type checking (Phase 1), type params are treated as fresh unification variables, just like HM inference already does for untyped parameters. Explicit `<T>` syntax is therefore mostly documentation at this stage — the constraint machinery is already in place.
- Explicit type params enable cleaner error messages and are required when the return type mentions a parameter not constrained by the arguments (e.g. `fn default<T>() -> T`).

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
- Two instantiations with different type arguments are distinct types.

**Implementation notes:**

- `StructDecl` in `MetaAst` gains a `type_params: Vec<String>` field.
- During type inference, when a struct literal `Pair { first: 1, second: "one" }` is encountered, unify each field's inferred type with the corresponding type parameter to produce a concrete instantiation.
- The monomorphizer (§6) creates a concrete version of each generic struct for each unique instantiation it encounters.

---

### 6. Monomorphization

Generics are implemented by **monomorphization**: the compiler produces one concrete copy of each generic function or struct per unique set of type arguments used in the program. There are no runtime type tags or boxing — each copy is fully specialized.

```cronyx
fn wrap<T>(x: T) -> [T] { return [x]; }

wrap(7);      // compiles to: fn wrap_int(x: int)  -> [int]  { return [x]; }
wrap("hi");   // compiles to: fn wrap_string(x: string) -> [string] { return [x]; }
```

The programmer never sees the mangled names — this is purely a compiler-internal transformation.

**Implementation notes:**

- Monomorphization runs as a new pass between `meta_stager` and `runtime_ast` conversion (or as part of the staged-forest processing).
- Maintain a work-list of `(fn_name, concrete_type_args)` pairs. Start by scanning the root statements for calls to generic functions. For each new instantiation found, specialize the function body by substituting all type parameters, then scan the resulting body for further generic calls.
- Generic structs are monomorphized on the same pass: each `StructDecl` with type params is replaced by one concrete `StructDecl` per distinct instantiation.
- Name mangling scheme (internal): `wrap__int`, `wrap__string`, `Pair__int__string`. Call sites are rewritten to use the mangled name.
- Recursive generic functions are supported as long as the recursion terminates at the type level (same requirement as Rust/C++).

---

## Design Notes

### Interaction with HM Inference

Cronyx already has parametric polymorphism via Hindley-Milner — `fn id(x) { return x; }` is already polymorphic. Explicit generics (`<T>`) layer on top:

- Without `<T>`: inferred implicitly, same behavior, but type errors may be harder to read.
- With `<T>`: the programmer documents the abstraction boundary; the compiler can produce precise errors ("expected `T`, found `int`").

Monomorphization happens *after* type checking. Phase 1 type-checking uses HM unification as today; monomorphization is then a code-generation step that produces the specialized copies.

### `self` is Not Special

`self` in a method is just a named parameter with a known type (the implementing struct). There is no implicit `this` pointer or reference semantics — Cronyx is a value-oriented language. Mutation of `self` inside a method does not mutate the original binding at the call site (same as any other function parameter).

### No `dyn` / Dynamic Dispatch

There is no trait object / dynamic dispatch in 0.1.4. All trait resolution is static — every call site must have a concrete type known at compile time. A future release may add `dyn Trait` for runtime polymorphism.
