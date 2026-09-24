# Metaprocessing

Status: **built.** `lib/metaprocess.ml` walks the program from its roots, runs each `meta` block where the walk meets it, instantiates templates as calls to them are reached, and walks what `gen` emits in place. `lib/precheck.ml` checks the whole program before the walk. The fixtures are `tests/meta/`, numbered in the order the ideas build on each other.

A `meta` block runs while the program is being compiled. Reaching one means compiling and running its dependencies, then continuing where compilation left off — so metaprocessing is recursive compilation.

**Literally so.** A block is handed to `Compile.program` — Desugar, Typecheck, Type_mono, Resolve, Reflect, Cps, Verify — and then to the interpreter: the same passes, in the same order, that the rest of the program goes through. There is no second interpreter and no compile-time subset of the language. What a block is compiled with is the prelude, the types and impls, each function it reaches — walked first, so nothing in it is still a meta block — and the block itself.

## Two things, not one

**`meta` runs code at compile time.** Braces are a block of statements rather than part of the form, so `meta print(x);` and `meta { … }` are the same thing at different sizes. Its output happens during compilation, before the program runs at all (`01_basic/basic`):

```cronyx
print("Top");
meta {
    print("Middle");
}
print("Bottom");
```

```
Middle
Top
Bottom
```

**`gen` emits code into the program.** The statement after it is captured as syntax and spliced in at the meta block's position, so it runs at runtime like anything else (`02_gen/basic`):

```cronyx
print("Top");
meta {
    gen print("Middle");
}
print("Bottom");
```

```
Top
Middle
Bottom
```

Same block, one keyword apart, opposite ordering. `gen` outside a meta block is an error, except in a function only a meta block calls — see [Functions](#functions).

## The walk

Metaprocessing is a walk from the **roots** — the entry file's top-level statements, or under `cx test` the tests — in source order. A declaration is metaprocessed the first time the walk reaches it, and once. What nothing reaches is never metaprocessed. This is Zig's lazy model, and for the same reason: a program with compile-time code has to decide what runs at compile time, and "what the program uses" is the only answer that does not make an unused function's `meta` a side effect of declaring it.

Before the walk starts, every written top-level declaration, and the members of every type, go into a table. So a body can call a function declared below it, a `derive` can use a deriver declared below it (`03_derive/deriver_below`), and a `meta` block that calls a function metaprocesses that function first (`05_order/27_meta_reaches_fn`: `helper meta` prints before `1`).

**Inside a body, everything is in source order.** A `meta` block runs when the walk reaches it, and a call to something not yet walked walks it there (`05_order/06_body_order`: `g<5>` before `f<5>`, because `f` calls `g` above its own `meta`). What a block generates is walked in place, as though it had been written there, so a call it generates is reached right after the block (`05_order/13_gen_call`: `f<1>`, `f<2>`, `f<3>`).

**Reaching is syntactic, not execution.** A call inside `if (false)` is reached; a call inside a function nothing reaches is not (`05_order/03_never`). A `meta` block in a loop runs once, and a call in a loop reaches its callee once (`05_order/23_meta_in_loop`, `24_call_in_loop`). A lambda's body is walked with the body it stands in (`05_order/25_meta_in_lambda`).

**Recursion terminates because a declaration is visited on entry.** `sum` calling itself, and `ping` and `pong` calling each other, run their `meta` once each (`05_order/04_recursion`, `05_mutual_recursion`). The one thing that cannot be done is a `meta` block calling a function whose own walk is still in progress — `'f' is still being metaprocessed, so a meta block cannot call it yet.` — since its body is not finished and so cannot be compiled.

**What only a meta program reaches is not emitted.** `meta print(fib(3))` reaches `fib` for the meta program, which metaprocesses and checks it there; unless run-time code also calls `fib`, it does not appear in the program. Only what the running program reaches is emitted. Code nothing reaches is still checked — by the precheck, below — so leaving it out loses no diagnostics.

**The order of compile-time output is a contract.** It is a function of the order of the program's call sites, deterministic and stable: moving a call moves what a `meta` prints. [Meta Scope and Instantiation](Meta%20Scope%20and%20Instantiation.md) has the worked example.

### Templates

A function or type that takes a static *value* parameter is instantiated by the walk, and so is one taking only types whose body runs a `meta` block or reaches something that does. Such a template is instantiated when a call to it (or a `new` of it) is reached — depth first, so an instantiation that calls another makes that one before it finishes — and remembered under its name and its static arguments. The memo is shared by the whole program, modules included (`05_order/01_basic`, `02_nested`, `06_modules/template_two_importers`), and a template is visited on entry the same way a function is, so mutual recursion between templates terminates on its base cases (`05_order/20_template_mutual`).

A template whose parameters are only types and which runs no `meta` is not instantiated here: it is checked once, generically, and `Type_mono` copies it after checking, when inference has said which types it is used at.

Memoisation is the semantics, not an optimisation, and a static parameter is *bound* in an instantiation rather than substituted through it — both are argued in [Meta Scope and Instantiation](Meta%20Scope%20and%20Instantiation.md), which is the authority on what crosses into a `meta` block and what `gen` sends back.

There is **no limit** on instantiation. `fib<n + 1>` recursing without a base case does not terminate, the same as a run-time function that recurses without one. A depth budget is the evaluator's business, as below.

### Methods, impls and trait objects

The walk works out a value's type only from what it can see without the checker: `new X`, an annotation, a static argument, a literal, a `var` initialised from one of those, or a function's declared return type. That is enough to reach methods:

- A method call on a receiver of known type reaches that type's method. An inherent impl is reached a method at a time; a trait impl is reached whole, because a trait's methods are a unit and a table of them is what dispatch needs (`05_order/08_static_invoke`, `12_methods`: `unused` never runs its `meta`).
- A value converted to a trait object — passed to a parameter or assigned to a variable written as the trait — reaches its type's impl of that trait, whole, whether or not a method is ever called through it. Only the impls of types actually converted run their `meta`: in `05_order/09_dyn_invoke`, `Cow` implements `Speaker` and never prints.
- A method call whose receiver type the walk cannot see is an error only when a candidate method runs a meta block: *Cannot tell which 'x' this calls, and one of them runs a meta block; annotate the receiver's type.* Candidates that run none are walked anyway, since walking them changes nothing.

A static **type** argument is found the same way or it must be written, Zig's `anytype` rather than inference: `printSpeak<Cat>(cat)` in `05_order/07_type_mono`. An unannotated parameter is not an implicit static parameter here — it is the checker's to generalise, after the walk — so a template whose `meta` reads a type parameter needs that parameter written or visible at the call.

## What `gen` captures

Raw AST, not a value — but every name in it is checked against the meta environment on the way out.

**If the name is not bound at compile time**, it is emitted as an identifier and resolved later, in the program the code is spliced into.

**If it is bound**, its value is *reified* — turned back into the syntax that denotes it. A number becomes a literal, a tuple a tuple literal, an array an array literal, and an anonymous record a record literal (`02_gen/reify_tuple_field`, `reify_record_anonymous`). A value of a declared type keeps it: a struct is written as `new P { … }` and an enum value as `E::B(…)`, `E::A` or `E::C { … }`, recursively (`reify_struct`, `reify_generic_struct`, `reify_enum_unit`, `reify_enum_payload`, `reify_enum_struct_variant`, `reify_nested`). The interpreter carries the declared type's name on a record or variant it builds, read off the node's annotation, because the structure alone does not say it. Type arguments are not written: the checker infers them again, as it does for a `new Box<int> { … }` written by hand.

**If its value cannot be reified**, that is an error at the `gen`: *'f' is a function and cannot be written into generated code.* (`02_gen/errors/reify_fn`), and *'s' is a trait object and cannot be written into generated code.* (`02_gen/errors/reify_object`). A closure has no literal form, and an object's type is not a declaration to rebuild. See [Reify](Reify.md).

```cronyx
var y = 4;
meta {
    gen var x = y + 5;
}
print(x);        // 9
```

`y` is a runtime variable, so it is not bound at compile time. It stays `y`, and `y + 5` is evaluated at runtime (`02_gen/env`).

Whereas a meta-bound name is written out as its value (`02_gen/reify_list`, `reify_record`):

```cronyx
meta {
    var xs = [1, 2, 3];
    gen print(xs);
}
```

emits `print([1, 2, 3])`.

**A name bound on both sides means the meta binding** inside a `gen`, since the `gen` is written in the meta block. A declaration the `gen` itself makes is the exception: `var v = 100;` inside a generated function binds its own `v`, whatever the block bound (`02_gen/shadowed_local`).

### Promotion

Substitution is not limited to bare names. Inside a `gen`, the largest subexpression that reads a meta-scope value and otherwise only names what the meta program can see is evaluated while the block runs and written back as a literal; the rest stays syntax (`02_gen/promote`):

```cronyx
fn twice(n: int): int { print("twice " + str(n)); return n * 2; }

var y = 10;
meta {
    var a = 2;
    gen print(twice(a));         // emits print(4)
    gen print(twice(a) + y);     // emits print(4 + y)
    gen print(twice(y));         // emits print(twice(y))
}
```

Two limits keep the line between *now* and *later* where the author would draw it. A statement's own call is never evaluated whole, only its arguments — `gen print(xs)` is a `print` to emit, not one to make. And a static call is never evaluated, but its static arguments are: `gen f<a - 1>()` emits `f<1>()` (`05_order/19_gen_static_arg`), which is how a template asks for the next instantiation.

### Names

A **name position** — a declaration's name, a constructor's type, a field, a method, a type annotation — substitutes only for a `Name`. A string never becomes an identifier on its own; `"greet_" + n` has to say so, with `.as_name()`, which rejects text that could not be one (`code/errors/not_a_name`). That is the same objection that rules out passing a type as a string: characters carry no guarantee that anything answers to them.

```cronyx
meta {
    var names = ["alice", "bob", "charlie"];
    for (name in names) {
        var fn_name = ("greet_" + name).as_name();
        gen fn fn_name() {
            print("Hello " + name);
        }
    }
}

greet_alice();
greet_bob();
greet_charlie();
```

`fn_name` is not the function's name; its *value* is. Each turn of the loop emits a declaration called `greet_alice`, `greet_bob`, `greet_charlie`, with `name` baked into each body as a literal (`02_gen/greeting`).

### How a captured statement reaches the interpreter

`gen` has to run when control reaches it — inside a loop, inside a branch — so it is a runtime construct in the block's compiled program. But what it carries is *surface syntax*, and every IR after the front end has dropped that shape.

So a `gen` does not survive as a node. Captured statements go into a table the metaprocessor owns, and `gen S` lowers to a call:

```
gen S    ⟶    meta#emit(k, "n", n, …, "promoted#0", e, …)
```

`k` indexes the table; the pairs are the block's own bindings and the promoted subexpressions, each with its value. `meta#emit` looks up entry `k`, substitutes, and appends the result to whatever collector is running. The name is generated, so no program can write it, and it is bound only while a block runs.

**Which names get passed is a correctness matter.** Only names the block itself binds are sent, because a name it does *not* bind is a runtime name — mentioning it inside the meta block would not compile. That is precisely why `gen var x = y + 5;` works: `y` is never passed, so it is never substituted, and it survives as an identifier.

The table is shared across the whole run rather than per block, because a function that does `gen` is lowered once but called from many blocks.

## Nesting

A meta block inside a meta block is processed while the outer one is being compiled, so the innermost runs first (`01_basic/nested`):

```cronyx
print("A");
meta {
    print("B");
    meta {
        print("C");
    }
    print("D");
}
print("E");
```

```
C
B
D
A
E
```

`C` during the compilation of the outer block, `B` and `D` when that block runs, `A` and `E` at runtime.

## Processing is unconditional

Because a nested block is processed while the enclosing one is compiled, the enclosing block's control flow has no bearing on whether it runs:

```cronyx
meta {
    if (false) {
        meta { print("C"); }
    }
}
```

```
C
```

`C` is printed while compiling the outer block. The outer block then runs, evaluates `false`, and does nothing.

Three separate things, worth keeping apart:

- **Processing** a nested meta block happens during compilation of its parent, unconditionally.
- **Splicing** puts `gen` output at the position the meta block occupied — which, for a nested block, is inside the parent's body rather than in the program. A generated top-level *declaration* is emitted at the front of the program, so a function the walk enters later may call it; whether a use is allowed is decided by walk order, below, not by position.
- **Executing** spliced code follows ordinary control flow, so a statement generated inside a branch that is never taken never runs.

So control flow decides what *executes*, never what gets *processed*.

A meta block **inside a `gen`** is different. It is part of what the `gen` captured, so it is code for the level below, and it runs when the walk reaches the generated code — not with its parent. `02_gen/gen_meta` prints `B F D A C E G`: the outer block runs (`B`, `F`) and emits `print("C")` and a `meta`; the walk then reaches that `meta` where it landed and runs it (`D`), and the program prints the rest. A hand-written `meta` at the same position would run at the same moment, which is the point — generated code is ordinary code. Compare `02_gen/nested`, where the inner block is not inside a `gen` and so runs first, `D B F A C E G`.

## Functions

There is no `meta fn`. Writing one is *'meta fn' no longer exists; use static parameters and a meta block.* (`04_functions/errors/meta_fn`). `meta` is written on a block, never on a declaration, and a function runs at compile time because a meta block calls it. Three shapes cover what a compile-time function is for:

**A plain function called from a `meta` block** is compile-time computation. `fib` is an ordinary `fn`, equally useful at runtime, and the call site decides (`04_functions/dyn_fib`):

```cronyx
fn fib(n: int): int { … }

meta print(fib(3));     // at compile time
print(fib(5));          // at run time
```

**A function with static parameters whose body holds `meta` blocks** is code that depends on a compile-time value. Each instantiation runs its blocks with the arguments bound, and what they `gen` is that instantiation's body (`04_functions/static_fib`):

```cronyx
fn fib<n: int>(): int {
    meta if (n <= 1) {
        gen return 1;
    } else {
        gen return fib<n - 1>() + fib<n - 2>();
    }
}
```

**A function that does `gen`** — a *Gen function* — writes code for whichever `meta` block calls it, and what it generates lands at that block (`code/fold`, `03_derive/gen_in_helper`). `gen` is allowed in a meta block and in any function only a meta block calls; calling one from run-time code is *'make' performs Gen, which only a meta block handles.* (`03_derive/errors/gen_at_runtime`). The walk is what works this out: a function performs `Gen` when it holds a `gen` outside any meta block, or calls one that does. That it is not an effect in the checker's sense is [TODO](TODO.md)'s "`Gen` as an effect".

| | plain `fn`, called from `meta` | `fn f<n: int>()` holding `meta` | Gen function |
|---|---|---|---|
| Runs at compile time | when a meta block calls it | its meta blocks, once per instantiation | when a meta block calls it |
| What the call site gets | a value, inside the meta program | a call to that instantiation | what it `gen`s, at the calling block |
| Exists at runtime | if run-time code reaches it | one copy per argument list reached | never |
| Memoised | no | by name and arguments | no |

**Why there is no `meta fn`.** A marker on the declaration would make every call to it happen at compile time, with nothing at the call sites. Its parameters would take values evaluated in the meta program, which is what a static parameter is; its body would run while compiling, which is what a `meta` block is; and it would emit code, which a plain function called from a block already does. What it would add is a second set of rules — calls not memoised, no runtime form, a name that is a function in the source and nothing in the program — for no case the three shapes cannot write.

**A type must be a value to be passed as one.** A function called from a meta block takes values, and nothing takes syntax. So a deriver cannot take a bare type name; it takes `typeof(X).shape`.

## What a meta block can see

A meta block sees what exists at the moment the walk reaches it.

| Visible to a meta block                      |     |                                    |
| -------------------------------------------- | --- | ---------------------------------- |
| written declarations, anywhere in the unit   | yes | collected before the walk starts   |
| imported declarations                        | yes | reached through their module, below |
| its own locals                               | yes | it is running                      |
| a static parameter of the function it is in  | yes | as an ordinary value — see [Meta Scope and Instantiation](Meta%20Scope%20and%20Instantiation.md) |
| an enclosing meta block's locals             | no  | that block has not run             |
| run-time parameters and `var` bindings       | no  | they have no value while compiling |
| a declaration another block generated        | yes | if that block has already run      |

**Runtime variables are not in scope.** `var y = 4;` has no value while compiling — it is a binding the program will make later. That is exactly why `gen var x = y + 5;` works: `y` is unbound at compile time, so it passes through as an identifier. Reading one inside the block is an error that says so: *'d' is a run-time value and does not cross into a meta block.* (`05_order/errors/dynamic_in_meta`).

**A nested block cannot evaluate its parent's locals.** It is processed *before* the enclosing block runs, so anything the parent binds does not exist yet. `gen` is the way across, because it does not evaluate `msg` — it emits the identifier. The emitted code lands in the parent's body, and by the time the parent runs, `msg` is bound:

```cronyx
meta {
    var msg = "hello";
    meta {
        gen print(msg);    // prints "hello" when the outer block runs
    }
}
```

That is what lifting a level means. The nesting is lexical, the ordering is not, and `gen` is what moves code from one to the other.

### Generated names

**A generated name exists from the point its `meta` block runs.** A use the walk reaches before that — at top level, or in a body the walk entered first — is an error naming the block: *'greet' is used before the meta block that generates it.* (`05_order/17_gen_before`, `18_gen_before_top`), or for a derive, *… before the derive that generates it.* (`03_derive/errors/use_before_derive`). What decides it is walk order, not position in the file: `05_order/16_gen_after` declares `foo`, which calls `greet`, above the block that generates `greet`, and it works because `foo` is not walked until `foo()` below the block.

The rule is what makes the walk's single pass sound. A name nothing has generated yet might be generated by a block the walk has not reached, and the alternatives are to run blocks in some other order — a worklist ordered by what each block needs, which cannot see a computed name coming — or to resolve every use after every block has run, which a meta block calling a generated function cannot wait for. Walk order is the order the author can read.

A generated declaration a meta block calls needs no special treatment beyond this: once its block has run, it is in the table like one that was written.

**A declaration generated inside a function body is local to that body.** Each instantiation of a template gets its own, so two instantiations generating `helper` do not collide (`05_order/15_gen_local`). An `impl` has no local form, so generating one inside a function body is an error: *An impl cannot be generated inside a function body.*

**Two blocks generating the same name** are treated exactly as that name written twice by hand: *'greet' is already declared.*, at the second, whether each was written or generated (`02_gen/errors/duplicate_generated`, `core/functions/errors/duplicate_fn`; a type says *Type 'Point' is already declared.*, `core/types/errors/duplicate_type`). A generated declaration quietly replacing one the program wrote would be the mistake nobody finds.

## Generated code is ordinary code

Once metaprocessing finishes, `meta` and `gen` are gone and what they emitted is indistinguishable from what was written by hand. Everything downstream follows from that rather than needing its own rule:

- A generated `var x` binds the same `x` any surrounding code binds. There is no hygiene mechanism because there is no separate category of name.
- Generated code is walked where it lands, so a `meta` inside it runs then, and a call inside it reaches its callee then.
- Generated code is type checked, elaborated, and lowered by the ordinary passes, once, as part of the program it landed in.

## Types with members

A type declaration may carry members after its fields (or variants): `meta` blocks and functions. Fields come first, comma-separated with an optional trailing comma; the first member keyword ends them. A function taking an explicit `self` is a method, one without is static.

```cronyx
type Box<T> {
    item: T,
    meta print(typeof(T).name);
    fn get(self): T { return self.item; }
}
```

A type whose members are only functions is a type and an inherent impl, exactly as if the impl had been written separately. A type that takes a value parameter (`type Buf<n: int>`), or whose members run a meta block, is a **type template**: it is instantiated per argument list when `new Name<args> { … }` is reached, its meta blocks run then with the value arguments bound, and its functions become methods of the copy (`05_order/10_box`, `11_buf`, `12_methods`). One nothing constructs never runs its `meta` (`05_order/26_unreached_type`).

A copy is named by what it was made from — `Box<int>`, `Buf<4>` — which is the name `typeof` and diagnostics show, and `Buf<4>` and `Buf<8>` are different types: *Expected Buf<4>, got Buf<8>.* (`05_order/errors/distinct_instances`). Construction needs `new`; a unit type is written as its bare name, `Cat`.

A type's meta block may generate only its methods — *A type's meta block can generate only its methods.* Not built: field defaults, a meta block generating fields, and a value argument in a type annotation (`var b: Buf<4>`).

## Modules

**Importing a file loads its declarations only.** Its top-level statements run only when it is the entry file (`tests/core/modules/module_statements`), so a library cannot do work by being imported.

**An import is pure symbol resolution.** A module's top-level `meta` blocks and `derive`s count as declarations of that module, and they run the first time the walk asks the module for a name — once, however many modules import it. Moving an import line changes nothing, and a module nothing reachable reads from never runs its `meta` (`06_modules/first_reference`, `import_order`, `imported_once`, `unused_import`, `circular`). Declarations a module's `meta` generates take the module's prefix like its written ones (`06_modules/gen_export`); a statement it generates is dropped, as the module's own statements are.

This depends on every name saying which module it comes from, so imports stay qualified: `util.f`, `util.f<1>()`, `animals.Cat`, a selective `import { f } from "util"`, and `utils/*` qualifying each file by its name. A qualified name, including a trait and a type in a `derive`, resolves through its module (`06_modules/derive_across`, `derive_across_selective`, `template_across`). A `Name` read out of another module prints as written, `Cat`, though it is mangled internally. What an unqualified wildcard import would do is [TODO](TODO.md)'s "Wildcard imports and metaprocessing".

**A package artifact is not metaprocessed.** `cx build` writes each package's `.cxa` loaded and mangled but with its `meta` blocks unrun, because which copies of a template exist, and which of a module's blocks run, is decided by the program that uses it. The walk runs once, over the linked program, under `cx run` and under `cx test`, whose tests are its roots. It runs from the package root (`Build.within`), since the paths an artifact holds are relative to it. A file a `meta` block reads is therefore not an input of the artifact: the next run reads it again.

## Checking

The walk visits only what the program reaches, so checking only what it emitted would never report an error in a function nothing calls. Checking is therefore two-phase, the way C++ checks a template:

1. **`Precheck`** checks the whole loaded program, reached or not, on a copy with meta erased: a static value parameter becomes a local of its declared type, a function that held a meta block returns an unknown value, `code(…)` is unknown, and `meta` and `gen` are dropped. It runs the checker with `Typecheck.partial`, under which a name, type, trait, member or impl nothing has declared yet is unknown rather than an error, since a meta block may still declare it.
2. **The walk**, then the **full check** of what it emitted, `strict`.

`Pipeline.whole` reports the errors of both, dropping the precheck's duplicates of the full check's.

So `fn label<a: int>(b: string): string { return a + b; }` is an error even if it is never called, because `a` is an `int` whatever its value (`07_precheck/errors/unreached_value_param`). A body whose type depends on its `meta` is not, until an instantiation is reached that gets it wrong:

```cronyx
fn f<n: int>(): int {
    meta if (n % 2 == 0) { gen return 5; } else { gen return "hello"; }
}
```

`f<2>` is fine (`07_precheck/depends_on_meta`); `f<3>` is *Expected int, got string.* (`07_precheck/errors/instance_mismatch`). The precheck never reports an undefined name — a meta block may generate it, in the same body or another file (`07_precheck/generated_later`) — so the full check after the walk is what does. Nor does it report what is done with one: a tuple field, an index, a `match` or a `for` over a generated name, or over a variable initialised from one, is as unknown as the name (`07_precheck/alias_generated`, `02_gen/reify_tuple_field`, `reify_nested`). [Type System](Type%20System.md#checked-twice-before-metaprocessing-and-after) has the checker's side of this: the policy record and why it does not excuse every unpinned receiver.

## The evaluator is a parameter

Metaprocessing does not contain an evaluator; it takes one. Anything that can run the compiled form will do — today the tree-walking interpreter, later codegen plus a runtime, or something else entirely.

That keeps the recursion honest: compiling a meta block runs the same pipeline the program uses, and the thing at the end of that pipeline is supplied rather than assumed. It also puts limits where they belong. A step budget for runaway compile-time computation — an infinite loop in a block, or a template that never reaches a base case — is the evaluator's business, not the compiler's, and until it becomes a problem it is a developer error like any other infinite loop.

The same applies to what compile-time code may do. It can do anything the evaluator permits. Restricting file access or nondeterminism is a sandboxing decision for whatever is passed in, not a rule the language needs to state.

## `code` builds syntax, `gen` emits it

`gen` is a side effect: what follows it goes into the program being compiled. `code(e)` is a value — it hands back the syntax without running it, and nothing is emitted until a `gen` takes it (`code/fold`).

```cronyx
fn build() {
    var check = code(true);
    for (n in [1, 2, 3]) { check = code(check && n > 0); }
    gen fn all_positive(): bool { return check; }
}
meta build();
```

`check` is an ordinary local holding a `Code`. The fold is what joins the pieces, so there is no `join`, no operator-as-a-value, and no control flow inside `gen` — the loop that builds the code is the loop the language already has, which is the point. A template with a repetition marker can only repeat what the marker anticipated; this can sort the fields, skip one, or call a helper, and the helper is an ordinary function (`code/helper`):

```cronyx
fn doubled(v: Code): Code { return code(v + v); }
```

`code` works in a meta block and in any function only a meta block reaches. Reaching run time with one is *'code' is only allowed inside a meta block.* (`code/errors/outside_meta`).

**Only a bare identifier splices into a `code`.** Promotion is a `gen` rule; `self.eq(other)` inside a `code` is a call in the generated program, not a call to make now, however the callee is defined. That keeps the question *does this run now or later* from depending on resolving a name, which is why a computed piece is bound to a local first:

```cronyx
var one = compare(f.name);
check = code(check && one);
```

**`Code` and `Name` are compile-time types**, next to `Type`. A `Code` cannot reach a running program. A `Name` is ordinary once it is in hand; what is restricted is making one, since that is where a name could otherwise be forged.

**How it is built.** `code` reuses what `gen` already had. Both are lowered before the meta program runs — into a call carrying an index into a table of captured syntax, plus the meta-bound names in scope. `gen`'s call emits, `code`'s returns. The one difference is scope: lowering follows the names bound *up to that point*, because `var body = code(…)` cannot be handed `body`.

**A `Code` holds an expression.** A deriver that emits several statements wants `code { … }` as well, and the two are different modes with only one valid in a given position. It goes with `Gen` as an effect, which needs the same thing.

## Deriving

Generating an `impl` from a type's shape is what compile-time code is for, and it is the case the language should be good at: real code derives several traits at once, so the form takes a list and names the type once.

```cronyx
derive Eq, Ord, Hash, Clone, Debug for Dog;
```

A deriver is an ordinary function declared beside the trait it derives, bound to it by a `for` clause the way an `impl` is (`03_derive/basic`):

```cronyx
trait Hash {
    fn hash(self): int;
}

fn derive(shape: TypeShape) for Hash {
    match shape {
        TypeShape::Product(t, fields) => {
            gen impl Hash for t {
                fn hash(self): int { … built with `code`, above … }
            }
        }
        …
    }
}
```

**`derive A, B for X;` is a meta block** calling one deriver per trait with `typeof(X).shape` (`derive/two_traits`). It is reached like any other top-level `meta`, and what it generates lands at the `derive` — including an impl a helper the deriver calls generated (`03_derive/gen_in_helper`). The trait and the type may be qualified: `derive named.Named for animals.Cat;`.

**It takes a `TypeShape`, not a `Type`.** A `Type` cannot be passed anywhere — it answers a question where it stands — so the name of the type comes out of the shape with the fields. `Type.name` stays a string, because `typeof(f).name` is `(int) -> int`, which no identifier could be; a name that can be spliced exists exactly where a declaration does, so `Product` and `Sum` carry a `Name` and the other shapes do not.

**The name written is not the name registered.** Every deriver is called `derive`, which would collide; `for Hash` registers it under a hidden name per trait that no program can write. A second deriver for one trait is *Trait 'Eq' already has a deriver.* (`derive/errors/two_derivers`), and a `derive` naming a trait without one is *Trait 'Show' has no deriver.* (`derive/errors/no_deriver`). `Eq` is derived by the compiler unless the program writes its own deriver for it.

**Why `for Hash` rather than a member of the trait.** Binding by a clause keeps a trait what it is — signatures — and makes a mistyped trait name an error at the declaration rather than a derive that silently does not exist. It also allows a deriver for a trait you did not write: there are no orphan rules here, so `derive Hash for geom.Point;` is as legitimate as writing the impl by hand.

**Why a statement rather than an attribute on the declaration.** `derive … for …` can name an imported type, does not touch the type-declaration grammar, and reads as the `impl Hash for Dog` it generates.

**The keyword is sugar, and the function underneath stays available.** A deriver taking extra arguments, or a second one for the same trait, is an ordinary function called from a meta block (`code/derive_eq`):

```cronyx
meta derive_eq(typeof(Dog).shape);
```

## Not built

- **`Gen` as an effect**, and handling it in a program to test a deriver — [TODO](TODO.md).
- **`code { … }`** for statements and declarations, above.
- **What a meta program inherits** from the prelude, and **what compiling one per block costs** — [TODO](TODO.md).
- **Field defaults, a `meta` generating fields, and value arguments in type annotations**, under [Types with members](#types-with-members).
