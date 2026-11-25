Reflection is a programming capability that lets a program inspect, analyze, and modify its own structure, types, metadata, and behavior.

Cronyx uses reflection as a pillar of metaprocessing.

## Code
Typically when you write code, it gets scanned, parsed, then passed along for metaprocessing, type checking etc. However, you can actually use the keyword `code` to turn that code into an object representing the AST:

```
var c = code(print("Hello, World!"));
```

The variable c now holds the object representation of the AST for `print("Hello, World")`. This object is just an ordinary object and can be used like any other object in cronyx.

# Code Gen
In cronyx you can also generate code modifying your program. This is done by the `gen` keyword.
```
meta {
	gen code(print("Hello, World!"));
}
```
During metaprocessing inside of that block, code will resolve to the ast and gen will emit that ast where it was called from before processing the outer chunk resolving in code looking like:
```
print("Hello, World");
```

NOTE - code is implicit when using `gen`
```
meta {
	gen print("Hello, World!");
}
```

### Using Code
Code is just an object in cronyx so anything that you can use an object in you can use code for.
```
var c = code(print("Hello, World!"));
print(c)
```
This will print the code AT RUNTIME. Even though cronyx has no runtime reflection, the code is lowered into object form at compile time and the object may exist at runtime.

You can also have functions that use code
```
fn code_inspector(c: Code) {
	print(c);
}

code_inspector(code(print("Hello, World")));
```

## Modifying Code
We can use code as an object, but we can also modify code! Lets say we have the following code:
```
var c = code(print("Hello World"));
```
But we actually want it to print "Hi!" instead, we can modify the code itself.

```
meta {
	var c = code(print("Hello World"));
	match c.kind {
        ExprKind.Call(call) => {
            call.args[0] = code("Hi!");
        }
        _ => {}
    }
    gen c;
}
```
Now this prints "Hi!"

## Adding a Parameter
We can modify declarations the same way. Lets say we have the following function:
```
var c = code fn greet() { print("Hello"); };
```
But we actually want `greet` to take a name and print `"Hello, " + name`, we can add a parameter and rewrite the body.

```
meta {
    var c = code fn greet() { print("Hello"); };
    match c.kind {
        DeclKind.Fn(f) => {
            f.params.push(Param {
                name: "name".as_name(),
                ty: Option.Some(TypeExpr.of(TypeKind.Named("string".as_name()))),
                implicit: false
            });
            f.body = code { print("Hello, " + name); };
        }
        _ => {}
    }
    gen c;
}
```
Now `greet("Brendan")` prints "Hello, Brendan".

# Declof
`code` turns what you write into an AST, but often the code we want is already written somewhere else. Lets say we have the following function in a module:
```
fn greet() {
    print("Hello");
}
```
`code(greet)` would only give us the expression `greet`, not the function. Instead we use `declof` to get the declaration itself:
```
var d = declof(greet);
print(d);
```
This prints the declaration of `greet`, the same object `code fn greet() { print("Hello"); }` would give us.

You can also have functions that use declarations
```
fn decl_inspector(d: Decl) {
    print(d);
}

decl_inspector(declof(greet));
```

# CPS
Because code is an ordinary object, a whole transform can be an ordinary function. Lets say we have a handler that takes the rest of the computation as `k`:
```
/**
 * Answers `ask` with 5, then carries on once the continuation returns.
 *
 * @param k the rest of the computation, given the answer
 */
fn ask(k: (int) -> <Console> unit) {
    print("asked");
    k(5);
    print("resumed");
}
```
And a block that calls it as if it returned a value:
```
var base = 10;
var n = ask();
print(base + n);
```
We can rewrite the block so everything after `ask()` becomes the continuation `ask` is handed.

```
/** A call that suspends, and the variables its continuation binds. */
type Split {
    call: Expr,
    params: List<Param>
}

/**
 * The name `e` refers to, or the empty string if it is not a variable.
 *
 * @param e the expression being called
 */
fn callee_name(e: Expr): string {
    match e.kind {
        ExprKind.Var(f) => { return str(f); }
        _ => { return ""; }
    }

/**
 * Whether `e` is a call that suspends.
 *
 * @param e   the expression to check
 * @param ops the names of the functions that take a continuation
 */
fn suspends(e: Expr, ops: List<string>): bool {
    match e.kind {
        ExprKind.Call(callee, _) => {
            return ops.contains(callee_name(callee));
        }
        _ => { return false; }
    }
}

/**
 *
 * @param e      the expression to check
 * @param params the variables its continuation binds
 * @param ops    the names of the functions that take a continuation
 */
fn split_call(e: Expr, params: List<Param>, ops: List<string>): Option<Split> {
    if (!suspends(e, ops)) { return Option.None; }
    return Option.Some(Split { call: e, params: params });
}

/**
 * `var x = init;` as a split, if `init` suspends.
 *
 * @param x    the variable being declared
 * @param init what it is initialised with, if anything
 * @param ops  the names of the functions that take a continuation
 */
fn split_let(x: Name, init: Option<Expr>, ops: List<string>): Option<Split> {
    match init {
        Option.Some(e) => {
            var p = Param { name: x, ty: Option.None, implicit: false };
            return split_call(e, [p], ops);
        }
        _ => { return Option.None; }
    }
}

/**
 * `s` as a split, if it is a statement that suspends.
 *
 * @param s   the statement to check
 * @param ops the names of the functions that take a continuation
 */
fn split_at(s: Stmt, ops: List<string>): Option<Split> {
    match s.kind {
        StmtKind.Let(x, _, init) => { return split_let(x, init, ops); }
        StmtKind.Expression(e) => { return split_call(e, [], ops); }
        _ => { return Option.None; }
    }
}

/**
 * The split's call, handed `rest` as its continuation.
 *
 * @param split the call that suspends
 * @param rest  the statements that run once it resumes
 */
fn resumed(split: Split, rest: List<Stmt>): Stmt {
    match split.call.kind {
        ExprKind.Call(callee, args) => {
            var inferred = Signature {
                ret: Option.None,
                row: Option.None,
                static_params: []
            };
            var k = Expr.of(ExprKind.Lambda(split.params, inferred, rest));
            var with_k: List<Expr> = [];
            for (a in args) { with_k.push(a); }
            with_k.push(k);
            var call = Expr.of(ExprKind.Call(callee, with_k));
            return Stmt.of(StmtKind.Expression(call));
        }
        _ => { return Stmt.of(StmtKind.Expression(split.call)); }
    }
}

/**
 * `ss` with everything after the first call that suspends moved into that
 * call's continuation.
 *
 * @param ss   the statements to rewrite
 * @param from the index to start at
 * @param ops  the names of the functions that take a continuation
 */
fn cps(ss: List<Stmt>, from: int, ops: List<string>): List<Stmt> {
    var out: List<Stmt> = [];
    for (var i = from; i < ss.len(); i += 1) {
        match split_at(ss[i], ops) {
            Option.Some(split) => {
                out.push(resumed(split, cps(ss, i + 1, ops)));
                return out;
            }
            _ => { out.push(ss[i]); }
        }
    }
    return out;
}

meta {
    var body = cps(code {
        var base = 10;
        var n = ask();
        print(base + n);
    }, 0, ["ask"]);
    for (s in body) { gen s; }
}
print("after");
```
The block becomes:
```
var base = 10;
ask((n) => { print((base + n)); });
```
Now this prints:
```
asked
15
resumed
after
```
