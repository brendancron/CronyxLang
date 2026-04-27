# Meta Functions

## Overview

A meta function is a named, reusable compile-time function. Where a `meta {}` block
is an anonymous compile-time expression evaluated once at its declaration site, a
`meta fn` is callable by name from any `meta {}` block and participates in the full
symbol system — including exports across module boundaries.

Meta functions do not exist at runtime. Their declarations are stripped from the
runtime AST entirely.

---

## Declaration

```
meta fn pluralize(word) {
    return word + "s";
}
```

The `meta fn` prefix is the only difference from a regular function declaration.
Everything else — parameters, body, return, recursion — works the same way.

---

## Call Sites

Meta functions may only be called from within `meta {}` blocks.

```
meta {
    var label = pluralize("widget");  // ok — inside meta block
    print(label);                     // prints "widgets" at compile time
}

pluralize("widget");  // error — meta fn called outside meta context
```

This rule ensures the compile-time / runtime boundary is always visible at the
call site. If you are reading a `meta {}` block you know everything inside it
runs at compile time.

---

## Code Generation

Meta functions may use `gen` to emit runtime statements. Generated statements
appear **at the call site** — the location of the `meta {}` block that called
the function — not at the definition site of the function.

```
meta fn make_printer(name) {
    gen print(name);
}

meta {
    make_printer("hello");
    make_printer("world");
}

// Runtime AST after metaprocessing:
// print("hello");
// print("world");
```

This means a meta function has no fixed output location. The same meta function
called from two different `meta {}` blocks emits code at each of those locations
independently.

---

## Return Values

Meta functions can return values that are used within the calling meta block.

```
meta fn type_label(x) {
    return typeof(x);
}

meta {
    var t = type_label(some_var);
    gen print(t);
}
```

---

## Recursion

Meta functions support full recursion. All execution occurs at compile time.

```
meta fn repeat(name, n) {
    if n == 0 {
        return;
    }
    gen name();
    repeat(name, n - 1);
}

meta {
    repeat("greet", 3);
}

// Runtime AST after metaprocessing:
// greet();
// greet();
// greet();
```

---

## Functions as Arguments

Functions are values in Cronyx. A meta function can accept a regular function
as an argument and pass it to `gen` or use it to drive code generation.

```
meta fn make_wrapper(inner_fn, label) {
    gen fn wrapped() {
        print(label);
        inner_fn();
    }
}

meta {
    make_wrapper(greet, "calling greet");
}
```

---

## Exports

Meta functions are exported by default, the same as regular functions. An
importing file can call an exported meta function from any of its own
`meta {}` blocks.

```
// utils.cx
meta fn make_getter(field) {
    gen fn get_{field}(obj) {
        return obj.{field};
    }
}
```

```
// main.cx
import "utils";

meta {
    utils.make_getter("x");
    utils.make_getter("y");
}
```

---

## Runtime Behavior

Meta function declarations are absent from the runtime AST. From the runtime's
perspective a `meta fn` never existed — only the code it generated via `gen` is
present.

| Construct | Present at runtime |
| --- | --- |
| `fn foo() { ... }` | Yes |
| `meta { ... }` | No — replaced by its generated output |
| `meta fn foo() { ... }` | No — stripped entirely |
| `gen` statement inside a meta fn | Yes — emitted at call site |

---

## Calling Regular Functions from Meta Functions

A meta function may call other meta functions, including recursively.
Calling regular (runtime) functions from meta context is handled separately —
see [Symbol Discovery with Metaprocessing](Symbol%20Discovery%20with%20Metaprocessing.md).
