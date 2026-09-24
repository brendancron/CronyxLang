Many languages skew the definitions of "static" vs "dynamic" in their language. In cronyx it is simple: static means it is resolved at compile time, dynamic means it is resolved at runtime. None of the java static definitions mean outside a class. Static simply means that the given data is resolved at compile time.

Lets start simply with an example:
```
fn addPrint(a: int, b: int) {
	print(a + b);
}

addPrint(3, 4);
```
Here this code prints `7`. The addition happens at run time, out of two arguments the function is handed.
How could we do this statically?
```
fn addPrintStatic<a: int, b: int>() {
	print(a + b);
}

addPrintStatic<3,4>();
```
Through instantiation, this method becomes "baked" with 3 and 4 as params: the metaprocessing walk makes one copy per static argument list when it reaches a call. Although it seems similar to the previous example it is important to note that `addPrintStatic<3,4>()` is a physically different function to `addPrintStatic<5,6>()` since they are statically resolved.

# Static and Dynamic constructs
cronyx has many different static and dynamic constructs. The simplest dynamic construct is a variable that is subject to change throughout program execution:
```
int x = 3;
int y = 4;

// valid use of a dynamic construct in a dynamic context
addPrint(x, y);

// invalid use of a dynamic construct in a static context!
addPrintStatic<x, y>();
```

You can also have a "static" variable (exact notation is tbd). But essentially what a static variable does is it is manipulated at compile time.

```
fn someFunc<a: int, b: int>() {
	print("start");
	addPrintStatic<a, b>();
	print("end");
}
```
This usage is 100% valid since a and b are both static variables and get erased by compile time.

# Meta and Static
We have covered meta in other places but a great example is a meta block can only be interacted with static constructs.
```
fn some(x: int) {
	// invalid usage of a dynamic construct in a static context
	meta print(x);
}

fn someStatic<x: int>() {
	// VALID usage of a static construct in a static context
	meta print(x);
}
```
The metaprocessing walk settles the ordering: `someStatic`'s `meta` block runs when a call to it is reached, once per instantiation, with `x` bound to that instantiation's value. In `some`, `x` is rejected — "'x' is a run-time value and does not cross into a meta block." See [Meta Scope and Instantiation.md](Meta%20Scope%20and%20Instantiation.md).

# Static vs Dynamic Dispatch
Okay this is the core of what we have been getting to. This is the most important one for many programming languages.

Lets say we have the following trait:
```
trait Speaker {
	fn speak(self);
}

type Cat;
type Dog;

impl Speaker for Cat {
	fn speak(self) {
		print("meow");
	}
}

impl Speaker for Dog {
	fn speak(self) {
		print("woof");
	}
}
```
This is a pretty trivial example that most people should be familiar with. Now lets show a usage:
```
var azalea = Cat;
var sherbert = Dog;

azalea.speak(); // meow
sherbert.speak(); // woof
```
Yay! Its working perfectly! Note: this is static dispatch, all methods are known by the compiler and therefore methods can be invoked directly.

Now lets look at a dynamic invocation:
```
var speaker: Speaker = Cat;

speaker.speak();
```
As you can see in this example the reference is actually typed with the trait type not the absolute type. This means there is dynamic invocation here since the actual function cannot be known at compile time. 
## Polymorphsim
Here is an example of referential polymorphism
```
var speakers: List<Speaker> = [Cat, Dog];
for (var speaker in speakers) {
	speaker.speak();
}
```
## Polymorphic Functions
Likewise we might want to create a function for a specific type
```
fn speakHelper<S: Speaker>(speaker: S) {
	speaker.speak();
}
```
In this example S actually gets bound to one specific type of speaker so the location of speak is exact per monomorphized instance.

```
fn speakDynHelper(speaker: Speaker) {
	speaker.speak();
}
```
In this example the speaker is again the reference to Speaker and therefore the speak invocation is dynamic since it is a dynamic construct.
# Where a trait object comes from

Inference never produces one. `var azalea = Cat;` is a `Cat` and stays one — unifying `Cat` with `Dog` is an error, not a reason to reach for a trait they share. A trait object exists only where a trait was *written* as a type:

```
var speaker: Speaker = Cat;              // a binding with a written type
speaker = Dog;                           // an assignment into one
fn announce(s: Speaker) { ... }          // a declared parameter
fn pick(): Speaker { return Cat; }       // a declared return
var all: List<Speaker> = [Cat, Dog];     // a written element type
type Pen { occupant: Speaker }           // a declared field
pen.occupant = Dog;                      // an assignment into one
```

That restriction is not a convenience. Checking is Hindley-Milner, which is unification over equality: `t1 = t2`, symmetric, with no way to say `t1 <= t2`. A coercion is subtyping, so it cannot be something inference discovers — it has to be something the checker *inserts* where an expected type is already known. The alternative is a constraint system with subtyping, HM(X) or algebraic subtyping, and the price is inferred types carrying unions and intersections through every diagnostic the compiler prints. Trait objects are the only subtyping in the language, so they do not justify it.

The consequence worth knowing is the element type. Without its annotation, `[Cat, Dog]` is an error — two unequal element types and nothing to unify them to. The annotation is what does the work, not the literal, which is why an argument whose parameter mentions a trait is *checked* against that parameter rather than inferred and unified afterwards: by the time a literal has been inferred, its elements have already been unified with each other and the coercion has nowhere to go.

Going the other way is not a coercion at all:

```
fn announce<S: Speaker>(s: S) { ... }
announce(speaker);   // 'speaker' is a 'Speaker' object; '<S: Speaker>' needs the type behind it
```

The bound monomorphizes, so it needs the type the object is hiding. The two are spelled with the same name, which is why this has a diagnostic of its own rather than the `Expected Speaker, got Speaker` that unification would print.

A type that does not implement the trait is rejected where it is written, and so is a trait that cannot have an object at all:

```
var quiet: Speaker = Rock;   // 'Rock' does not implement 'Speaker'.
```

# What an object is

The data, beside the functions chosen for it. `Resolve` meets the coercion the checker inserted, reads the concrete type off it, and builds one entry per method the trait's closure declares — a supertrait's methods are reached through the value like any other, so the table owes them a slot too — each entry the plain function that impl already became. Dispatch is still static in the sense [Elaboration](Elaboration.md) means it: nothing is searched at run time, the table is built at compile time, and only *which table* a value carries is unknown until it is.

The interpreter needs a real table rather than a type tag: a record value holds its fields and nothing else, so `Cat` and `Dog` — both of them fieldless — are the same value at run time. Nothing about the data says which impl answers. Codegen would carry the same pair for the same reason.

A method call on a trait-typed receiver becomes a call through that table. It is a resolved callee that reads its target from a slot, which is why `Verify` still rejects an unresolved one — and why it also checks the table against the trait it claims to be, so a slot the trait never declared, or a method the table has no slot for, is caught before the interpreter has to have an opinion about it.

## Effects travel with the call

A row cannot be read off a vtable, so the method's own type travels with the call site. One call sequence is emitted, and the row decides how many evidence parameters it appends, so every impl has to agree on that row: the trait declares it and an impl repeats it, and an impl that writes a different one — or omits a row the trait wrote — is a conformance error like any other signature mismatch.

```
trait Speaker { fn speak(self): <Ask> string; }
impl Speaker for Cat {
    fn speak(self): string { ... }
    // 'Speaker' for 'Cat' declares 'speak' as (self): <Ask> string
    // but defines (self): string.
}
```

Written rather than inferred, deliberately: an impl whose row was inferred from its body would make adding a `perform` to that body a change to how every caller of the trait is compiled. The gap that leaves is an impl performing an effect neither it nor the trait wrote down, which is still accepted and still reaches the interpreter — `tests/core/traits/errors/impl_row_inferred` is that case, waiting in `known_unsound`.

With the row settled, the call passes the evidence — or the continuation — that a named call to the same impl would have passed. A handler that resumes in tail position and one that resumes after doing more work both work through an object.

## What a trait object cannot be

A slot is reached through the value, so every method the trait declares must take a receiver:

```
trait Maker {
    fn make(): int;      // 'Maker' cannot be used as a type: 'make' takes no receiver.
    fn show(self): string;
}
```

`Maker` remains perfectly usable as a bound — `<M: Maker>` monomorphizes and needs no table. It is only the object that is impossible, so the error belongs at the coercion rather than at the declaration, where nothing is yet wrong.

Two further cases are worth naming even though neither is reachable today. A method mentioning `Self` in an argument could not be typed through an object — two `Speaker` values may be a `Cat` and a `Dog`, and `Cat`'s method would be handed a `Dog` — but `Self` cannot currently be written in a signature at all. A method with static parameters of its own would need one slot per instantiation, which no finite table holds; the intended restriction is that a trait method uses only the parameters the trait declares, and until that is written down the grammar still accepts one.

# What it costs

An indirect call, and the inlining that the direct call would have allowed. Not an allocation: the intent is that a normal type is heap-allocated already, so pairing it with a table moves no data. A `flat` type is the exception, and the exception is deliberate — it was written `flat` to say the value lives in place, and an object needs it not to. That coercion takes an explicit box, which is the open question [TODO](TODO.md) carries.
