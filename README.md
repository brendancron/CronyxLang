# Cronyx

A statically-typed, metaprogramming-first language with Hindley-Milner type inference.

See [docs/Cronyx.md](docs/Cronyx.md) for a language overview.

# Installation

## Package Managers

### Windows

#### Scoop

Add the bucket
```
scoop bucket add cronyx https://github.com/brendancron/scoop-cronyx
```

Install
```
scoop install cronyx
```

Update
```
scoop update
scoop update cronyx
```

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

# Usage

```
cronyx <source.cx> [flags]
```

## Flags

| Flag | Description |
|------|-------------|
| `--dump-ast` | Write `meta_ast.txt` and `meta_ast_graph.txt` to the output directory |
| `--dump-typed-ast` | Write `meta_ast_typed.txt` and `type_table.txt` |
| `--dump-staged` | Write `staged_forest.txt` and `staged_forest_graph.txt` |
| `--dump-runtime-ast` | Write `runtime_ast.txt` and `runtime_ast_graph.txt` |
| `--dump-runtime-code` | Write `runtime_code.cx` (pretty-printed generated source) |
| `--dump-all` | Enable all of the above |
| `--out-dir <path>` | Directory to write debug files into (default: `./out`) |

Debug files are only created when at least one `--dump-*` flag is passed. Without any flags the compiler runs and exits with no file I/O beyond the program itself.

### Example

```
cronyx main.cx --dump-runtime-code --out-dir debug/
```