# CronyxLang

A statically-typed, metaprogramming-first language with Hindley-Milner type inference.

See the [documentation](https://brendancron.github.io/CronyxLang/) for a language overview.

# Installation

It is recommended to install the cronyx compiler via the build manager

## Package Managers

### MacOS

#### Homebrew

Add the tap
```
brew tap brendancron/cronyx
```

Install
```
brew install cronyx
```

Update
```
brew update
brew upgrade cronyx
```

This installs one complete toolchain: `cx`, which links the compiler rather
than shelling out to it, and the standard library it resolves `import "std/…"`
against. There is nothing further to install to start writing Cronyx.

A release carries one archive per architecture, and the formula names a version
per architecture too, so `brew upgrade` moves each one as its archive lands.

### Linux

```
curl -fsSL https://brendancron.github.io/CronyxLang/install.sh | sh
```

It picks the archive for the machine it is on, checks it against the checksum
published beside it, and installs into `~/.local`. `CRONYX_PREFIX` puts it
somewhere else and `CRONYX_VERSION` asks for a release other than the latest.
The Linux archives are linked statically against musl, so the distribution does
not matter.

The tap works here too, if you already use Homebrew on Linux:

```
brew tap brendancron/cronyx
brew install cronyx
```

### Anything else

Build it — OCaml 5 and dune:

```
git clone https://github.com/brendancron/CronyxLang
cd CronyxLang/bootstrap
opam install . --deps-only --yes
cd ..
dune build
```

`cx` is `_build/default/cx/bin/main.exe`, and it finds the standard library at
`../lib/cronyx/stdlib` relative to itself, so install the two together:

```
mkdir -p ~/.local/bin ~/.local/lib/cronyx
cp _build/default/cx/bin/main.exe ~/.local/bin/cx
cp -R stdlib ~/.local/lib/cronyx/stdlib
```

`CRONYX_STDLIB` overrides that search if you would rather keep them apart --
which is what a package manager that installs through a shim rather than a
symlink needs.

## Toolchains

What `cx` installs later is *other* toolchains. A package names the compiler it
needs in `cronyx.toml`, and that is a floor rather than a pin: a newer `cx` runs
the package itself, and an older one hands the job to the named version if it is
installed, or says where to get it if it is not.

```
cx toolchain list
cx toolchain install 0.0.2 ./cronyx-v0.0.2-x86_64-apple-darwin/bin/cx
```

Install takes the version and the `cx` to install as it, unpacked from a
[release](https://github.com/brendancron/CronyxLang/releases) — there is no
download step yet. Installing a newer toolchain also makes it the `cx` on your
`PATH`; installing an older one leaves that alone, so the dispatcher only ever
moves forward.

# Starting a package

```
cx new hello
cd hello
cx run
```

`cx build` compiles the package and its dependencies, `cx publish` uploads it,
and `cx toolchain list` says which compilers are installed. A package names the
compiler it needs in `cronyx.toml`, and `cx` hands the job to that one.

# Running a program

```
cx run main.cx
```

Inside a package, `cx run` takes no path: it builds the package and runs what
the manifest points at.

## Flags

Each dump prints one stage and then runs the program.

| Flag             | Description                                                          |
| ---------------- | -------------------------------------------------------------------- |
| `--dump-source`  | The source as the scanner received it                                 |
| `--dump-tokens`  | The token stream                                                      |
| `--dump-ast`     | The parsed tree                                                       |
| `--dump-types`   | The tree after checking, every node annotated                         |
| `--dump-code`    | The program as Cronyx after metaprocessing — what a `gen` produced    |
| `--locked`       | Fail if the lockfile would change                                     |
| `--offline`      | No network; the cache or nothing                                      |
| `--frozen`       | Both                                                                  |
| `-h`, `--help`   | Print help and exit                                                   |

`cx version` prints the toolchain version. `--locked`, `--offline` and
`--frozen` apply to `cx build` as well.
