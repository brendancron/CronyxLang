# Inlining

This is a partial plan to replace algebraic effects. In my opinion these will serve the language better and are more of a natural fit.

## Static vs Dynamic Greeting

Let's say you are a coder on a feature and you want to greet someone in your program, you might reference a greet function:

```
greet("Brendan");
```

as a programmer you can just use the greet function which takes in a dynamic string and returns unit.

```
fn greet(name: string): unit
```

but the internals for that function are actually unknown to you, greet may just print "Hello, <name>" or it might print "Heya, <name>" or it could do any other combination.

In many programming languages you would do this by essentially passing in a greet function pointer.

```
fn my_func(greet: (string) -> unit) {
    var name = "Brendan";
    greet(name);
}
```

Cronyx static params do not take functions yet, but under this proposal greet could be one:

```
fn my_func<greet: (string) -> unit>() {
    var name = "Brendan";
    greet(name);
}
```

Having greet be static means all dispatch can also be determined statically and greet calls are "fast". It can also potentially lead to code explosion if you have too many definitions of greet at once. There are real pros and cons to the implementation you choose.

Only a function known at compile time can be a static argument. A named top-level function is one. A closure that captures runtime locals is not, because its value is not known until the program runs.

### Example

```
fn my_func<greet: (string) -> unit>() {
    var name = "Brendan";
    greet(name);
}

fn greet1(name: string): unit {
    print("Hello, " + name);
}

fn greet2(name: string): unit {
    print("Heya, " + name);
}

my_func<greet1>();
my_func<greet2>();
```

This code will output:

```
Hello, Brendan
Heya, Brendan
```

## Types with Static Params

So the same concept for a function can be done on types:

```
type Greeter<greet: (string) -> unit> {
    fn welcome(name: string) {
        greet(name);
    }
}
```

This is an extremely simple example but we are building up to the big stuff. Notice that in this example you cannot welcome with different types of greetings as the greeting is pinned at the type level. Now you could do a different type of implementation if you really wanted to:

```
type Greeter {
    fn welcome<greet: (string) -> unit>(name: string) {
        greet(name);
    }
}
```

where the greet function is static on the welcome function, just note that this means code explosion. And the Greeter potentially has lots of variations of the welcome method (not just 1). Probably in this instance having the greet at the type level is more appropriate.

## Inlining a function

What does it mean to inline a function? At a high level it means cutting and pasting code in place of the function call.

```
inline fn double_add(a: int, b: int): int {
    return (a + b) * 2;
}

print(double_add(3, 4));
```

for this example the inline keyword means that the method gets inlined during metaprocessing so this code literally processes to:

```
print((3 + 4) * 2);
```

note that double_add does not exist for the processed code. Instead the code is inlined so there is no extra function call. Again there is a tradeoff. If you use double_add all over the place you pay in code expansion, but save all of the extra function calls.

An inline call still evaluates each argument exactly once, just like a normal call. Pure substitution would get this wrong when the body uses a parameter twice:

```
inline fn square(a: int): int {
    return a * a;
}

print(square(next()));
```

Pasting the argument in directly gives `print(next() * next())`, which calls `next()` twice. Instead, the argument is bound first:

```
{
    var a = next();
    print(a * a);
}
```

When an argument is trivial, there's no temporary. A literal is pasted in as-is, and so is a variable the inlined body never assigns to. That is why `double_add(3, 4)` above becomes `(3 + 4) * 2`, with no extra variables. The assignment rule matters: if the body did `a = a + 1` and the caller passed its own `x`, pasting `x` in would change the caller's variable, which a normal call never does.

An inline function can `return` early, and the `return` exits the inlined body, never the caller:

```
inline fn clamp(x: int): int {
    if (x < 0) { return 0; }
    return x;
}

var y = clamp(n) + 1;
```

Each `return` becomes an assignment to a result variable, and whatever follows it moves into an `else`, so nothing after the `return` runs:

```
var clamp_result: int;
if (n < 0) {
    clamp_result = 0;
} else {
    clamp_result = n;
}
var y = clamp_result + 1;
```

A `return` inside a loop also has to stop the loop. A body with only a final `return` needs none of this, which is why `double_add` becomes a plain expression.

An inlined body's locals are renamed so they never clash with the caller's, the same way `clamp_result` is given a fresh name:

```
inline fn greet1(who: string): unit {
    var msg = "Hello, " + who;
    print(msg);
}

fn my_func<greet: (string) -> unit>() {
    var msg = "Brendan";
    greet(msg);
}
```

Pasted in naively, `var msg = "Hello, " + msg;` would read the inlined `msg` in its own initializer and lose the caller's. With renaming, the copy is:

```
fn my_func#0() {
    var msg = "Brendan";
    var greet1_msg = "Hello, " + msg;
    print(greet1_msg);
}
```

An inlined body's names resolve where the function was defined, not where it is called:

```
// greetings.cx
fn prefix(): string { return "Hello, "; }
inline fn greet1(who: string): unit {
    print(prefix() + who);
}

// main.cx
import "greetings";
fn prefix(): string { return "Bye, "; }
greetings.greet1("Brendan");
```

This prints "Hello, Brendan". The inlined `prefix()` is still `greetings.prefix`, even though `main` has a `prefix` of its own and never imported the one from `greetings`.

An inline function that calls itself, directly or through another inline function, never finishes expanding:

```
inline fn fact(n: int): int {
    if (n <= 1) { return 1; }
    return n * fact(n - 1);
}
```

Nothing checks for this. It is the programmer's mistake, the same as an infinite loop in a `meta` block, and metaprocessing will not terminate.

The inlining can happen at a static level, so you could have:
```
fn my_func<greet: (string) -> unit>() {
    var name = "Brendan";
    greet(name);
}

inline fn greet1(name: string): unit {
    print("Hello, " + name);
}

inline fn greet2(name: string): unit {
    print("Heya, " + name);
}

my_func<greet1>();
my_func<greet2>();
```

This code has the same output as the first version, but the processed version is quite different. In this example the print stmts actually get inlined in my_func so it looks like:

```
fn my_func#0() {
    var name = "Brendan";
    print("Hello, " + name);
}

fn my_func#1() {
    var name = "Brendan";
    print("Heya, " + name);
}

my_func#0();
my_func#1();
```

greet1 and greet2 no longer exist because they are inline. Passing them as static arguments alone would not remove them: without `inline`, each copy of my_func would still call greet1 or greet2 directly, just with no dynamic dispatch. If you try to do the dynamic version:

```
fn my_func(greet: (string) -> unit) {
    var name = "Brendan";
    greet(name);
}

inline fn greet1(name: string): unit {
    print("Hello, " + name);
}

my_func(greet1);
```

there is no call site to paste greet1 into, since my_func takes a runtime function value. In that case greet1 gets an ordinary out-of-line copy, emitted only because something used it as a value:

```
fn my_func(greet: (string) -> unit) {
    var name = "Brendan";
    greet(name);
}

fn greet1(name: string): unit {
    print("Hello, " + name);
}

my_func(greet1);
```

Calls to greet1 are still inlined everywhere else. The copy follows the same reachability rule as everything else: if nothing uses greet1 as a value, it does not exist.
