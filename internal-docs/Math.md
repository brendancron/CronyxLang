# Mathematics

`std/math` is the numeric library: elementary functions over `float`, arithmetic over `int` that the operators leave out, the traits that let one function serve every number type, and the types and statistics built on them. [Stdlib Plan](Stdlib%20Plan.md#9-mathematics) says what order it lands in.

## Shape

| Module | Holds |
| --- | --- |
| `math/Math` | Free functions over `float` and `int`, the generic ones over `math/Num`, and the constants |
| `math/Num` | `Ord`, `Zero`, `One`, `Num`, `Signed`, `Pow`, and their impls for `int`, `float` and `BigInt` |
| `math/BigInt` | Integers of any size |
| `math/Rational` | Exact fractions over `BigInt` |
| `math/Complex` | Complex numbers over `float` |
| `math/Stats` | Summaries of any `Iterable<float>` |

Nothing here is global. A program imports what it uses, and importing a function by name is what makes it callable with a dot:

```cronyx
import { sqrt, floor } from "std/math/Math";

var x = 10.0;
print(x.sqrt().floor());   // 3.0
```

## A dot is a free function

`x.sqrt()` is `sqrt(x)`: a dot falls back to a function whose first parameter takes the receiver when the receiver's type has no method of that name ([Type System](Type%20System.md#settled)). So `float` and `int` get no `impl` in this library. Every function is an ordinary declaration, which means:

- **The import is the opt-in.** A file that never names `sin` never has it, so a program's own `fn round` is never contested by a library one it did not ask for. `import "std/math/Math"` still gives `Math.sqrt(x)`; only a name brought in by `import { … }` is reachable through a dot, because the dot resolves the name the way a bare reference does.
- **An impl still answers first.** `BigInt` keeps its own `abs` and `pow`, and `n.abs()` on a `BigInt` reaches them rather than anything imported.
- **A trait method is opted into the same way.** `2.pow(10)` reaches `Pow`'s impl only in a file that has `Pow` in scope: by importing it by name, by importing `math/Num` whole, or by being the module that declares it. Loading `math/Num` somewhere else in the program does not make it reachable here. The operators are the exception: `+` reaches `Add` wherever it is written, since its traits are in every file.
- **One declaration serves both spellings.** The reference documents `sqrt` once, and `Math.sqrt(x)` and `x.sqrt()` are the same call.

## One name, one meaning

Cronyx has no overloading. A module cannot hold a `pow(int, int)` beside a `pow(float, float)`, and a program importing `pow` has to get one function. That splits the library by how many types a name applies to.

**A name with one sensible type is a plain function on it.** `sqrt`, `sin`, `ln` and `floor` mean something only on `float`; `gcd`, `isqrt` and `floor_div` only on `int`. Each takes that type and nothing else, so inference has nothing to choose and an error names the type.

**A name every number has is a trait method.** `abs`, `sign` and `pow` are declared once in `math/Num` and implemented for `int`, `float` and `BigInt`, so the call is spelled the same at every type and dispatches statically through the impl:

```cronyx
import { Pow } from "std/math/Num";
import { BigInt } from "std/math/BigInt";

print(2.pow(10));                // 1024
print((2.0).pow(0.5));           // 1.4142135623730951
print(BigInt.of(2).pow(100));    // 1267650600228229401496703205376
```

`BigInt.abs` and `BigInt.pow` become its impls of `Signed` and `Pow` rather than methods beside them, which is what lets a generic function take a `BigInt`.

**A name built from those is a generic function.** `min`, `max`, `clamp`, `sum`, `product` and `lerp` are written once against a bound, so the next number type gets them by implementing the traits.

## `float`

Each function below is a native that is one `libm` call. Natives are what a native backend implements as its C runtime ([Native Readiness](Native%20Readiness.md)), and one that is a single `libm` symbol costs that runtime nothing.

| Group | Functions | `libm` |
| --- | --- | --- |
| Rounding | `floor`, `ceil`, `trunc`, `round`, `round_even`, `fract` | `floor`, `ceil`, `trunc`, `round`, `rint`, `x - trunc(x)` |
| Powers | `sqrt`, `cbrt`, `hypot` | `sqrt`, `cbrt`, `hypot` |
| Exponentials | `exp`, `exp2`, `exp_m1` | `exp`, `exp2`, `expm1` |
| Logarithms | `ln`, `log2`, `log10`, `ln_1p`, `log(x, base)` | `log`, `log2`, `log10`, `log1p`, `log(x) / log(base)` |
| Trigonometry | `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2` | same names |
| Hyperbolic | `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh` | same names |
| Classification | `is_nan`, `is_infinite`, `is_finite`, `is_sign_negative` | `isnan`, `isinf`, `isfinite`, `signbit` |
| Sign and fusion | `copysign`, `fma` | `copysign`, `fma` |
| Steps | `next_up`, `next_down` | `nextafter` toward ±infinity |
| Angles | `to_radians`, `to_degrees` | written in Cronyx |

The natives are `__float_<name>` in `builtins.ml`, with an empty doc so the reference shows the Cronyx wrapper and its doc comment rather than the native.

**A domain error is NaN, not a panic.** `sqrt(-1.0)`, `ln(0.0 - 1.0)` and `acos(2.0)` return NaN, and `ln(0.0)` is negative infinity, as IEEE 754 and `libm` define them. A panic would make every numeric loop decide in advance which inputs it might meet, and NaN already propagates through arithmetic to where someone checks `is_nan`. A caller who wants a failure checks the input or the result.

**NaN and the infinities print as `NaN`, `inf` and `-inf`.** Spelled by the compiler rather than by C's `printf`, whose NaN carries its sign bit and differs between C libraries, so a program prints the same on every platform. `==` on floats is IEEE 754's: NaN equals nothing, itself included, and `-0.0 == 0.0`. `same(x, x)` is still true for a NaN, since it compares identity.

**`round` rounds half away from zero.** `round(2.5)` is `3.0`, as people round by hand and as C's `round` does; `round_even` is banker's rounding for whoever is summing many of them.

**Converting to `int` is a separate function.** `x.to_int()` truncates and panics on NaN, an infinity, or a value outside `int`'s range. `floor`, `ceil` and `round` all return `float`, so a NaN stays representable until something asks for an integer.

## `int`

| Group | Functions |
| --- | --- |
| Number theory | `gcd`, `lcm`, `isqrt`, `is_power_of_two` |
| Division | `floor_div`, `floor_mod`, `euclid_div`, `euclid_mod` |
| Checked | `checked_add`, `checked_sub`, `checked_mul`, `checked_pow`, each `Option<int>` |
| Wrapping | `wrapping_add`, `wrapping_sub`, `wrapping_mul` |
| Saturating | `saturating_add`, `saturating_sub`, `saturating_mul` |
| Bits | `count_ones`, `leading_zeros`, `trailing_zeros` |

**`/` and `%` truncate, so the floor versions exist.** `-7 / 2` is `-3` and `-7 % 2` is `-1`, matching C and `BigInt`. Arithmetic on calendars and grids wants the floor: `floor_div(-7, 2)` is `-4` and `floor_mod(-7, 2)` is `1`, and `os/Time` has needed a private `__floor_div` for exactly that, which this replaces. `euclid_mod` is never negative whatever the divisor's sign, which is what an index into a ring buffer wants.

**`gcd` is never negative**, and `gcd(0, 0)` is `0`. `lcm` of anything with `0` is `0`. `isqrt(n)` is the largest `r` with `r * r <= n`, computed by Newton's method on integers rather than through `float`, which loses the answer above 2^53. A negative argument panics, as dividing by zero does: there is no `int` that is the answer.

**`checked_*` means "outside `int`'s range", whatever that range is.** `int` is 63 bits under the interpreter and its native width is undecided ([Native Readiness](Native%20Readiness.md#3-representations-decided)). The checked, wrapping and saturating functions are defined against `int_max()` and `int_min()` rather than a bit count, so their meaning survives that decision: what bare `+` does at the edge of a native `int` is the open part, and a caller who uses these does not depend on it. A fixture that pins the boundary uses those functions rather than a literal.

## Constants

An imported module contributes declarations and nothing else; its top-level statements never run ([Modules](Modules.md)). A `let PI` in `math/Math` would therefore be unbound for every importer, so each constant is a function of no arguments:

| Function | Value |
| --- | --- |
| `pi()`, `tau()`, `e()` | π, 2π, e |
| `sqrt2()`, `ln2()`, `ln10()` | √2, ln 2, ln 10 |
| `infinity()`, `neg_infinity()`, `nan()` | the IEEE specials |
| `epsilon()` | the gap between `1.0` and the next `float` |
| `float_max()`, `float_min_positive()` | the largest finite `float`, the smallest positive normal one |
| `int_max()`, `int_min()` | the ends of `int` |

```cronyx
import "std/math/Math";

var area = Math.pi() * r * r;
```

This costs a call and gives up only the spelling.

The spelling wanted eventually is a `const` declaration: a top-level binding whose initializer is evaluated at compile time and that is exported like a function, so `Math.PI` is a name rather than a call. It would be a declaration the walk metaprocesses the first time something reaches it, as it does a `fn`, and evaluated there with the interpreter, which is why an imported unit's statements not running does not stand in its way. When it exists, each function above becomes a `const` of the upper-case name, and the function is removed rather than kept beside it.

## Traits

`math/Num` holds:

```cronyx
trait Ord: PartialOrd {
    fn cmp(self, rhs: Self): Ordering;
}

trait Zero { fn zero(): Self; }
trait One { fn one(): Self; }

trait Num: Zero, One, Add<Self, Output = Self>, Sub<Self, Output = Self>,
           Mul<Self, Output = Self>, Div<Self, Output = Self> {}

trait Signed: Num, Neg<Output = Self> {
    fn abs(self): Self;
    fn sign(self): Self;
}

trait Pow<E> {
    fn pow(self, exponent: E): Self;
}
```

**A bound is one trait, so a combination is a trait.** A parameter takes a single bound, and `T: Add + Mul` does not parse. `Num` is how "a number" is written once, with supertraits doing the work `+` would, and it has no methods of its own.

**`Zero` and `One` are associated functions.** `T.zero()` reaches the type's own through its bound ([Type System](Type%20System.md#settled)), which is what lets `sum` start from nothing:

```cronyx
fn sum<T: Num>(items: List<T>): T {
    var total = T.zero();
    for (x in items) { total = total + x; }
    return total;
}
```

**`float` is `PartialOrd` and not `Ord`.** NaN compares to nothing, so a total order over `float` would be a lie that a sort trusts. `int`, `string`, `char` and `BigInt` are `Ord`. `float` gets `total_cmp`, IEEE's total order with NaN at the ends, as a function for whoever needs to sort floats and has decided where NaN goes.

Nothing in the library requires `Ord` yet. `algo/Sort` takes `PartialOrd`, so a `List<float>` sorts, and moving it to `Ord` would break every program that does that; it is a decision of its own. `Ord` is declared so that its first consumer, an ordered map for one, has the impls waiting.

The implementations are `Pow<int>` for `int` and `BigInt` (a negative exponent panics) and `Pow<float>` for `float`. A method is found by its name and not by its argument's type, so `float` holding both `Pow<float>` and `Pow<int>` would make `(2.0).pow(3)` ambiguous; an `int` exponent on a `float` is written `x.pow(n.to_float())`. `int`, `float` and `BigInt` are `Signed`. A `sign` is `-1`, `0` or `1` in the type's own terms; on `float` it is `copysign(1.0, x)` for a non-zero `x`, `x` itself for a zero, so `-0.0` keeps its sign, and NaN for NaN.

The generic functions in `math/Math` are bound by these:

| Function | Bound | Defined as |
| --- | --- | --- |
| `min`, `max` | `PartialOrd` | the first argument when the two are equal or do not compare |
| `clamp(x, low, high)` | `PartialOrd` | `max(low, min(x, high))`; panics if `high < low` |
| `abs`, `sign` | `Signed` | the impl |
| `sum`, `product` | `Num` | a fold from `zero()` and `one()` |
| `lerp(a, b, t)` | `Num` | `a + (b - a) * t` |

`min` returning its first argument when they do not compare means `min(nan(), 1.0)` is NaN and `min(1.0, nan())` is `1.0`. That is the honest answer of the bound, and the alternative, where NaN always loses, belongs to `float` and not to `PartialOrd`; it is `float`'s `fmin` and `fmax`, both `libm`.

## `Rational`

```cronyx
import { Rational } from "std/math/Rational";

var third = Rational.of(1, 3);
print(third + Rational.of(1, 6));   // 1/2
```

A `Rational` is a `BigInt` numerator over a positive `BigInt` denominator with no common factor, and every operation returns one in that form. Reducing every time keeps `==` structural: two equal fractions are the same pair, so `Eq` is the derived one and nothing has to cross-multiply. Over `int` the numerator overflows after a handful of additions, which is what a type for exact arithmetic exists to avoid.

It implements `Num`, `Signed`, `Ord`, `Pow<int>`, `Display` (`1/2`, and `3` for a whole number) and `Debug`; `Eq` is `derive Eq for Rational;`. Its fields are `numerator` and `denominator`. It is made with `Rational.of(n, d)` from `int`s or `Rational.of_big(n, d)` from `BigInt`s, and has `to_float`, `from_float` and `is_whole`. `from_float` is exact: every finite `float` is a dyadic fraction, so `from_float(0.1)` is `3602879701896397/36028797018963968`, which is the truth about `0.1`. NaN and the infinities are `None`. Dividing by zero panics, as it does on `int`.

## `Complex`

A `Complex` is a pair of `float`s, `re` and `im`, made with `Complex.of(re, im)` or `Complex.from_polar(r, theta)`. It implements `Num`, `Neg`, `Eq`, `Pow<Complex>`, `Display` (`1.0+2.0i`, `1.0-2.0i`) and `Debug`, and has `conj`, `abs`, `arg`, `exp`, `ln` and `sqrt`; `exp`, `ln`, `sqrt` and `pow` take the principal branch.

It is not `PartialOrd`. There is no order on the complex plane that agrees with arithmetic, and a type that answers `<` with something invites code that trusts it. This is why `Num` has no `PartialOrd` among its supertraits: the functions that compare, `clamp`, `min` and `max`, ask for it on their own, and `sum` over a `List<Complex>` needs no order. `Complex.abs` is the magnitude and returns `float`, so `Complex` is not `Signed`, whose `abs` returns `Self`.

## Statistics

`math/Stats` summarizes anything that is `Iterable<float>`, which `List` and `Array` both are:

```cronyx
fn mean<C: Iterable<float>>(items: C): Option<float>
```

`Iterable<T>` is a trait in `core` with one method, `iter(self): Iter<T, <>>`, implemented for `List` and `Array`. With no overloading, a bound is the only way one function takes both. It is a bound rather than a parameter of type `Iterable<float>`, which would be a trait object and dispatch at run time.

| Function | Answer |
| --- | --- |
| `mean`, `median` | `Option<float>` |
| `variance`, `stddev` | the population figures, `Option<float>` |
| `sample_variance`, `sample_stddev` | divided by `n - 1`, `None` below two items |
| `quantile(items, q)` | linear interpolation between the closest ranks, `q` in `[0, 1]` |
| `min_of`, `max_of` | `Option<float>`, ignoring NaN |

**Empty is `None`, not NaN.** The mean of nothing has no value, and NaN would be read as "a value went wrong" when nothing did. The `Option` makes the caller say what an empty sample means for them.

**Mean and variance are one pass of Welford's method.** Summing and dividing loses digits when the values are large and close together, and summing squares loses them sooner; Welford's update keeps a running mean and a running sum of squared differences from it, and stays accurate where the naive formula goes negative.

`median` and `quantile` collect the items into a list and sort that, so the input is left as it was.

What numpy adds beyond this, vectors, matrices and element-wise functions over them, is not in `std/math`. `linspace` and `arange` are ranges and belong in `iter/` if anywhere.

## What the language owes the library

Each of these is a gap in the language that the library cannot paper over, and each is fixed with a fixture of its own before the functions that depend on it.

**`const` is wanted, not required.** The constants work as functions; `const` changes their spelling and nothing else.
