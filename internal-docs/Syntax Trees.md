# Syntax Trees

Status: **built.** `stdlib/compiler/Ast.cx` and `Printer.cx`, the conversion in
`bootstrap/lib/syntax.ml`, and the fixtures in `tests/meta/syntax/`.

Cronyx code as ordinary Cronyx data: a sum type per kind of syntax, in the
standard library, which a `meta` block builds, takes apart and hands to `gen`.
It replaces `Code`, an opaque value that only ever holds an expression.

## Why

A deriver writes code whose shape depends on the type it was handed. `gen`
writes its body out with each meta variable filled in, and a variable stands
for one thing, so what `gen` writes has the shape its body was written with. `Eq` gets by because `&&` can wrap a finished
expression in a bigger one, one field at a time:

```cronyx
var check = code(true);
for (f in fields) {
    var field = f.name;
    check = code(check && self.field == other.field);
}
```

Nothing wraps a record literal into a bigger one with one more field, so
`Decode` cannot write `Config { name: …, port: …, verbose: … }` for a type it
has not seen. A `match` with an arm per variant has the same problem, and so
does a `Cli` parser with a case per flag. A splice form for each — a list of
fields here, a list of arms there — is a growing set of special cases. The
general answer is that a piece of syntax is a value of a type that says what
kind of syntax it is, built with the data structures and loops the language
already has:

```cronyx
var entries: List<FieldInit> = [];
for (f in fields) {
    var key = str(f.name);
    entries.push(FieldInit { name: f.name, value: code(d.field(key)) });
}
var body = Expr.of(ExprKind.Record(t, [], entries));
gen impl Decode for t {
    fn decode(d: Decoder): t { return body; }
}
```

This is Template Haskell's `Exp`/`Dec`/`Pat` with `recConE`, Rust's `syn`
(`Expr`, `Item`, `FieldValue`) and OCaml's ppxlib. Each separates kinds of
syntax by type, and offers quotes for writing it and the tree for building it.

## What the types are

A mirror of the **surface syntax**, as it is written, not of the compiler's
internal `Ast`. The internal tree carries what later passes need — mangled
names, annotations, stages from `desugared_expr` to `cps_stmt` — and changes
whenever a pass does. The library tree changes only when the language's
syntax does, so a deriver written against it keeps working while the
compiler underneath it moves. `syn` is to `rustc` what this is to the
bootstrap.

```cronyx
type Expr { kind: ExprKind, span: Span }

type ExprKind {
    Int(int),
    Str(string),
    Var(Name),
    Field(Expr, Name),
    Call(Expr, List<Expr>),
    MethodCall(Expr, Name, List<Expr>),
    Binary(BinOp, Expr, Expr),
    Record(Name, List<TypeExpr>, List<FieldInit>),
    Variant(Name, Name, List<Expr>),
    Lambda(List<Param>, Option<TypeExpr>, List<Stmt>),
    Match(Expr, List<MatchArm>),
    …
}

type FieldInit { name: Name, value: Expr }
type MatchArm { pattern: Pattern, body: List<Stmt> }

type Stmt { kind: StmtKind, span: Span }

type StmtKind {
    Let(Name, Option<TypeExpr>, Expr),
    Assign(Expr, Expr),
    Expression(Expr),
    Return(Option<Expr>),
    If(Expr, List<Stmt>, List<Stmt>),
    For(Name, Expr, List<Stmt>),
    …
}

type Decl { kind: DeclKind, span: Span }

type DeclKind {
    Fn(FnDecl),
    Impl(ImplDecl),
    Type(TypeDecl),
    …
}
```

`Pattern`, `TypeExpr`, `Param`, `BinOp` and the declarations' records complete
it. It covers every form the surface syntax has, so any quote converts and any
program can be written as a tree: there is no opaque node standing in for a form
the tree has not caught up with, and no syntax that cannot be quoted. A form
added to the language is added here in the same change.

**Every node carries its span**, as a record of a kind and a span — rustc's
`Expr { kind, span }`, and the bootstrap's own `node`. A quote's nodes take
their spans from the source. A node built by hand is made with `of`, which marks
its span as generated, and `gen` gives such a node its own location when it
emits it:

```cronyx
var one = Expr.of(ExprKind.Int(1));
var sum = Expr.of(ExprKind.Binary(BinOp.Add, x, one));
```

Spans are in the shape from the start because `compiler/Parser` will need them
on every node it produces; adding them afterwards would change every node a
deriver had been written against.

`Name` is the compiler's built-in identifier type, so a name from a
`TypeShape` goes straight into a tree and `as_name()` stays the one way to make
one from text.

**Reflection stays in `meta/Reflect`.** `TypeShape`, `TypeField`,
`TypeVariant`, `Attr` and `TypeRef` describe types and answer what a meta block
asks about the program; the tree is syntax, and part of the compiler as a
library. A deriver reads one and builds the other, so it takes `TypeShape` from
the prelude as now and imports the tree:

```cronyx
import { Expr, ExprKind, FieldInit } from "std/compiler/Ast";
```

## How it meets the compiler

**`code(…)` is a quote.** It parses as today and evaluates to an `Expr`. There
is no `Code` type: one representation of syntax means no conversion at every
boundary, and every quote can be taken apart. A deriver that only splices reads
the same as before, with `Expr` where it wrote `Code`: the captured tree is converted from the compiler's
representation into the library's when the call runs, with the meta-bound
names substituted first, as now.

**Statements and declarations are quoted too.** `code { … }` is a
`List<Stmt>`, and `code` before a declaration is a `Decl`, held rather than
emitted. A deriver that assembles an impl from a varying set of methods quotes
each, collects them, and emits the impl once, which `gen impl … { … }`
cannot do because its methods are fixed when it is written:

```cronyx
var body = code { var v = parse(arg); return v; };
var get = code fn get(self): int { return 1; };
var methods: List<Decl> = [get];
gen Decl.of(DeclKind.Impl(ImplDecl { …, methods: methods }));
```

**A meta variable splices by the kind of its value.** In the body of a `gen` or
a quote, a bare name bound to an `Expr` stands where an expression does, a
`List<Stmt>` where a block's statements do, a `Name` where a name does. A value
in the wrong position is an error when the body is written out, naming both
kinds. Every other meta value is promoted as today.

**`gen` takes a tree.** `gen d;` with `d` a `Decl` emits it, so a deriver can
build a whole declaration rather than only fill one in. `gen` followed by
syntax stays: it is a quote and an emit in one.

**The conversion is the compiler's.** One function each way between the
internal tree and the library's, written in OCaml beside `reflect.ml`, which
already builds `TypeShape` values the same way. A node the conversion meets in
the wrong direction — an internal form with no surface spelling — is a bug in
the compiler, not the program.

**Where generated code came from.** A node a quote produced carries the span
it was written at; a node built by hand takes the span of the place it is
spliced, or of the `gen` that emits it, so an error in the checked result
points into the deriver rather than at the user's `derive`. Saying which
`derive` or `meta` produced the code, as a note on the diagnostic, is not
built.

**Two things do not survive a round trip.** A `match` pattern has no span,
as it has none in the compiler. A method call keeps the method's name but not
the name the loader would give it as a free function, so `x.f()` that only
`f(x)` answers works when written and not when built.

## The compiler in the standard library

The tree lives in `std/compiler/`, the first part of a compiler written in
Cronyx, the bootstrap's eventual successor and the library a tool uses to read
Cronyx: a formatter, a linter, a language server.

- `compiler/Ast` — the tree above.
- `compiler/Printer` — a tree as source text, for a test of a deriver to print
  what it built. It writes names as the program wrote them, where
  `--dump-code` writes the names the compiler gave them, so the two agree on
  everything but a module-qualified name.

Later, each in its own milestone and none needed by derivers:

- `compiler/Token` and `compiler/Lexer`.
- `compiler/Parser`, which makes a quote's job a library call:
  `parse_expr("a + b")`.
- `compiler/Check` and what follows it.

While only the bootstrap can parse, a quote is the way into the tree from
source, and the compiler is the only producer of trees from text.

## What this does not settle

- **Hygiene.** A generated local can capture a name the user's code also uses —
  a parameter `d` in `decode` and a field called `d`. Fresh names (`gensym`)
  are the usual answer; when a deriver must use one is not decided here.
- **Typing by value.** `Expr` says a tree is an expression, not that it is an
  `int` expression; a string where an int belongs is caught when the generated
  code is checked, not when the deriver is. An index — `Expr<T>`, a GADT with
  `Add(Expr<int>, Expr<int>): Expr<int>` — is deferred until something needs
  it. It does not fit this tree as it stands: a deriver learns its field types
  as `TypeRef` values when it runs, so it would hold `Expr<?>` throughout; a
  variable's type depends on scope the tree does not track; and a parser builds
  the tree before checking, from text that may not check. A checked tree
  carries each node's type as data, as the bootstrap's `typed_expr` does, and a
  typed quote for staging would be a wrapper over `Expr` rather than a change
  to it.
- **`Gen` as an effect** ([TODO](TODO.md)) needs `Code` to hold declarations,
  which this gives it; handling `Gen` to test a deriver is a separate step.
