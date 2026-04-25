# Compilation Milestones

Each milestone is a complete Cronyx program that compiles to a native binary and produces correct output. They build linearly — each one proves the previous infrastructure works before adding new complexity.

---

## Milestone 0 — Print an Integer

```cx
print(to_string(1 + 2));
```

**Output:** `3`

**New infrastructure required:**
- inkwell / LLVM module setup
- `i64` arithmetic (`add`, `mul`, `sub`, `sdiv`)
- `VarDecl` → `alloca` + `store`
- `Call` → LLVM `call`
- Runtime library: `__print_string`, `__to_string_int`
- Emit object file, link to binary

This is the hardest milestone proportional to its size — all the scaffolding lives here.

---

## Milestone 1 — Fibonacci

```cx
fn fib(n: int): int {
    if (n <= 1) {
        return n;
    }
    return fib(n - 1) + fib(n - 2);
}

print(to_string(fib(10)));
```

**Output:** `55`

**New infrastructure required:**
- `FnDecl` → LLVM function definition with typed parameters
- `Return` → `ret`
- `If` / `else` → basic blocks + `br` / `cbr`
- Recursive `Call` (function must be declared before its own body references it)

---

## Milestone 2 — Struct

```cx
struct Point {
    x: int;
    y: int
}

fn distance_sq(p: Point): int {
    return p.x * p.x + p.y * p.y;
}

var p = Point { x: 3, y: 4 };
print(to_string(distance_sq(p)));
free(p);
```

**Output:** `25`

**New infrastructure required:**
- Heap allocation: `StructLiteral` → `malloc` + field `store`s
- `DotAccess` → `getelementptr` + `load`
- `free` → `free()` on the heap pointer
- Named LLVM struct types (`%Point = type { i64, i64 }`)
- Pass struct by pointer to function

---

## Milestone 3 — List + Loop

```cx
fn sum(xs: [int]): int {
    var total = 0;
    for (x in xs) {
        total = total + x;
    }
    return total;
}

var nums = [1, 2, 3, 4, 5];
print(to_string(sum(nums)));
free(nums);
```

**Output:** `15`

**New infrastructure required:**
- List literal → `malloc` for `{ i64 len, i64 cap, i64* data }`
- `ForEach` → loop with induction variable, bounds check
- Index access → `getelementptr` into data pointer
- ForEach variable type in TypeTable (Phase 2e)

---

## Milestone 4 — Closure

```cx
fn apply(f: fn(int): int, x: int): int {
    return f(x);
}

var double = fn(x: int): int { return x * 2; };
print(to_string(apply(double, 21)));
```

**Output:** `42`

**New infrastructure required:**
- Free variable analysis pass
- `Lambda` → named LLVM function + `malloc`'d closure env struct
- Closure call → extract `fn_ptr` and `env_ptr`, pass `env_ptr` as first arg
- Higher-order function parameter typed as function pointer pair

---

## Milestone 5 — Enum + Match

```cx
enum Option {
    Some(int),
    None,
}

fn safe_div(a: int, b: int): Option {
    if (b == 0) {
        return Option::None;
    }
    return Option::Some(a / b);
}

match safe_div(10, 2) {
    Option::Some(v) => print(to_string(v)),
    Option::None => print("division by zero"),
}
```

**Output:** `5`

**New infrastructure required:**
- Enum variant registry (Phase 2b)
- `EnumConstructor` → `malloc` tagged union, `store` tag + payload
- `Match` → `switch` on tag field, one basic block per arm
- Payload binding → `getelementptr` into payload region

---

## Milestone 6 — Algebraic Effect

```cx
effect Log {
    fn log(msg: string): unit;
}

fn greet(name: string) {
    log("hello, " + name);
}

with fn log(msg: string): unit {
    print(msg);
}

greet("world");
```

**Output:** `hello, world`

**New infrastructure required:**
- String heap layout: `{ i64 len, i8* data }`
- String concatenation → runtime call `__string_concat`
- `fn` effect handler → install function pointer in handler table
- Effect op call → indirect call through handler table
- Runtime library: string ops

---

## Feature → Milestone Dependency Table

| Feature | First needed at |
|---|---|
| inkwell setup, i64 arithmetic | M0 |
| `FnDecl`, `Return`, `If`, recursion | M1 |
| `while` loop | M1 (or standalone) |
| Struct heap layout, `DotAccess`, `free` | M2 |
| Named struct types (Phase 2c) | M2 |
| List heap layout, `ForEach`, index access | M3 |
| ForEach variable type (Phase 2e) | M3 |
| Free variable analysis | M4 |
| Closure env struct, fn pointer pair | M4 |
| Enum registry (Phase 2b) | M5 |
| `Match` → switch | M5 |
| String heap layout, concatenation | M6 |
| Effect handler dispatch | M6 |
| `ctl` effects + CPS continuations | M6+ |
| Generics (monomorphization already done) | falls out naturally |
| Traits / `impl` | after M5 |
| Modules / linking | after M6 |

---

## Recommended Order Within Each Milestone

Before starting M0, complete the Phase 2 prerequisites from `Path to LLVM.md`:
- **2a** TypeVar verification (30 min)
- **2b** Enum variant registry (needed at M5 but cheap to do early)
- **2c** Named struct types (needed at M2)
- **2e** ForEach variable type (needed at M3)

Then: M0 → M1 → M2 → M3 → M4 → M5 → M6.

Do not skip milestones. Each one exercises the previous infrastructure under new conditions and will surface bugs before the next layer is added.
