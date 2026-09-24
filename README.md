# Cronyx

A statically-typed, metaprogramming-first language with algebraic effects.

[Documentation](https://brendancron.github.io/CronyxLang/) ·
[Getting started](https://brendancron.github.io/CronyxLang/docs/getting-started) ·
[Releases](https://github.com/brendancron/CronyxLang/releases)

> Cronyx is at 0.0.x and experimental. Programs run on an interpreter, and the
> language changes between releases.

## Example

```cronyx
trait Named {
    fn type_name(self): string;
}

fn derive(shape: TypeShape) for Named {
    match shape {
        TypeShape::Product(t, fields) => {
            var label = str(t);
            gen impl Named for t {
                fn type_name(self): string { return label; }
            }
        }
        _ => {}
    }
}

type Point { x: int, y: int }
derive Named for Point;

effect log {
    fn log(msg: string): unit;
}

fn describe(p: Point) {
    log("a " + p.type_name());
}

run {
    describe(new Point { x: 1, y: 2 });
} handle log {
    fn log(msg: string) { print("[log] " + msg); }
}
```

```
[log] a Point
```

- **`fn derive(...) for Named`** is ordinary Cronyx that runs at compile time.
  It reads a type's shape through [reflection](https://brendancron.github.io/CronyxLang/docs/language-metaprogramming/reflection),
  and `gen` writes the impl into the program. A [deriver](https://brendancron.github.io/CronyxLang/docs/language-metaprogramming/deriving)
  is not a plugin or a macro language: it is a function.
- **`derive Named for Point`** calls that function with `Point`'s shape, and the
  impl lands where the `derive` is written. `--dump-code` prints the program
  after this has happened.
- **`effect log`** declares an operation without saying what it does.
  `describe` performs it without saying so in its signature: the checker
  infers `log` into `describe`'s type.
- **`run { … } handle log { … }`** decides what `log` means for the code
  inside. Swap the handler and `describe` is unchanged. Leave it out and the
  program does not compile. See [Why effects](https://brendancron.github.io/CronyxLang/docs/language-effects/why-effects).

## Why Cronyx

- **Metaprogramming is the language.** Compile-time code is ordinary Cronyx
  that reflects on types and generates code.
- **One mechanism for effects.** Errors, async, generators and IO are all
  effects, inferred by the type checker.
- **Inferred static types.** Hindley–Milner inference, with traits dispatched
  statically.

## Install

On Linux:

```
curl -fsSL https://brendancron.github.io/CronyxLang/install.sh | sh
```

The script picks the archive for your machine, verifies its checksum, and
installs `cx` and the standard library into `~/.local`. `CRONYX_PREFIX`
installs somewhere else, and `CRONYX_VERSION` picks a release other than the
latest.

On macOS, or Linux with Homebrew:

```
brew tap brendancron/cronyx
brew install cronyx
```

On Windows, download the `x86_64-pc-windows-gnu` zip from
[Releases](https://github.com/brendancron/CronyxLang/releases), unpack it, and
put its `bin` folder on your `PATH`. Keep `lib` beside it, since `cx` finds the
standard library there.

Anywhere else, [build it from source](#building-from-source).

## Quick start

```
cx new hello
cd hello
cx run
cx test
```

A single file needs no package: `cx run hello.cx`. See
[The cx command](https://brendancron.github.io/CronyxLang/docs/cli) for every
command and flag.

## Learn

The [documentation](https://brendancron.github.io/CronyxLang/) covers the
language from the basics through metaprogramming and effects.

## Building from source

You need OCaml 5 and dune:

```
git clone https://github.com/brendancron/CronyxLang
cd CronyxLang
opam install ./bootstrap --deps-only --yes
dune build
```

`cx` looks for the standard library at `../lib/cronyx/stdlib` relative to
itself, so install the two together:

```
mkdir -p ~/.local/bin ~/.local/lib/cronyx
cp _build/default/cx/bin/main.exe ~/.local/bin/cx
cp -R stdlib ~/.local/lib/cronyx/stdlib
```

Run the test suite with `dune test --root bootstrap`.

## License

Cronyx is licensed under the [Apache License 2.0](LICENSE).
