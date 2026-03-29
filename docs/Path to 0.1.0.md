# Path to 0.1.0

In version 0.1.0 I need the following MVP:
* A trivial project should be able to be created with the language
* The compiler/interpreter needs to be installable via package manager (Homebrew at minimum)
* I need a plan for version controlling the compiler moving forward

---

# Ascii Maze Solver

The project I'd like to make is the ascii maze solver. An ascii maze is imported via some file and the program spits out a solution.

Example input:
```
----+---+---+-----+-+
S   |   |   |     | |
+-- | | | --+ | | | |
|   | | |     | | | |
| --+ | +-+ +-+ | | |
|     |   | |   |   |
+-----+-+ +-+ +-+-- |
|       | |   | |   |
| | +---+ | +-+ | --+
| | |     | |   |   |
| +-+ +-+-+ | --+-- |
| |   | |   |       |
| | +-+ | | +-+ ----+
|   |     |   |     |
| +-+---+-+-+ +-+-+ |
| |     |   |   | | |
| | +-- | | +-- | | |
|   |   | |     | | |
+---+ --+ +-----+ | |
|         |         E
+---------+----------
```

Expected output:
```
----+---+---+-----+-+
S...|...|   |  ...| |
+--.|.|.| --+ |.|.| |
|...|.|.|     |.|.| |
|.--+.|.+-+ +-+.|.| |
|.....|...| |...|...|
+-----+-+.+-+.+-+--.|
|       |.|...| |...|
| | +---+.|.+-+ |.--+
| | |.....|.|   |...|
| +-+.+-+-+.| --+--.|
| |...| |  .|  .....|
| |.+-+ | |.+-+.----+
|...|     |...|.....|
|.+-+---+-+-+.+-+-+.|
|.|.....|...|...| |.|
|.|.+--.|.|.+--.| |.|
|...|...|.|.....| |.|
+---+.--+.+-----+ |.|
|    .....|        .E
+---------+----------
```

## Required Language Features

The maze solver drives the entire 0.1.0 feature set. Below is the exact list of language features needed, in rough implementation order.

### 1. Comparison Operators
`<`, `>`, `<=`, `>=`, `!=`

The tokens already exist in the lexer. Need to:
- Add cases to `parse_expr` in `parser.rs` (same pattern as `==`)
- Add `Lt`, `Gt`, `Lte`, `Gte`, `NotEquals` variants to `MetaExpr`, `StagedExpr`, `RuntimeExpr`
- Wire through stager, conversion, runtime AST `compact()`, gen_collector, type checkers
- Implement in `interpreter.rs` `eval_expr`
- Update `formatter.rs`

### 2. Logical Operators
`&&`, `||`, `!` (or keyword forms `and`, `or`, `not`)

`and` and `or` are already keywords in the lexer. `!` / `BangEqual` token exists.
- Add `And(usize, usize)`, `Or(usize, usize)`, `Not(usize)` to the expr ASTs
- Wire through the full pipeline same as comparisons
- `And`/`Or` short-circuit in the interpreter
- `Not` flips a bool value

### 3. While Loop
```
while (condition) {
    ...
}
```
Token already exists in the lexer. Need to:
- Add `TokenType::While` arm to `parse_stmt`
- Add `WhileLoop { cond: usize, body: usize }` to `MetaStmt`, `StagedStmt`, `RuntimeStmt`
- Wire through stager, conversion, runtime AST, gen_collector, type checkers
- Implement in interpreter: evaluate cond, loop body until false, respect `Return`

### 4. List Index Access
```
var row = grid[y];
var cell = grid[y][x];
```
This is the largest gap. Requires new expression and statement syntax.
- Add `Index { object: usize, index: usize }` to the expr ASTs
- Parse `expr[expr]` in `parse_factor` after any primary expression (postfix, like function calls)
- In the interpreter, evaluate `Index` on `Value::List` by unwrapping to the nth element
- On `Value::String`, return the nth character as a one-character `Value::String`

### 5. Index Assignment
```
grid[y][x] = ".";
```
Needed to mark the solution path on the maze.
- Extend `parse_stmt` assignment handling: detect `ident[expr] = expr` and `ident[expr][expr] = expr`
- Add `IndexAssign { name: String, indices: Vec<usize>, expr: usize }` to stmt ASTs
- In the interpreter, resolve the chain of indices into the nested list and mutate in place
- Lists are already `Rc<RefCell<Vec<Value>>>` so mutation is possible without structural changes

### 6. String Built-in Methods
Dispatch through the existing `DotCall` mechanism. Add a string method dispatch path in `eval_expr` for `DotCall` when the object is `Value::String`.

Methods needed:
| Method | Signature | Description |
|---|---|---|
| `str.len()` | `() -> int` | Character count |
| `str.split(delim)` | `(string) -> [string]` | Split by delimiter, returns list |
| `str.chars()` | `() -> [string]` | Each character as a one-char string |
| `str.trim()` | `() -> string` | Strip leading/trailing whitespace |
| `str.contains(sub)` | `(string) -> bool` | Substring check |

### 7. List Built-in Methods
Same approach — dispatch through `DotCall` when the object is `Value::List`.

Methods needed:
| Method | Signature | Description |
|---|---|---|
| `list.len()` | `() -> int` | Element count |
| `list.push(item)` | `(T) -> unit` | Append to end (mutates in place) |
| `list.pop()` | `() -> T` | Remove and return last element |
| `list.contains(item)` | `(T) -> bool` | Membership check (equality-based) |

### 8. Built-in Runtime Functions (I/O Helpers)
These are explicit stopgaps for 0.1.0 — not a proper stdlib. They mirror how `print` is implemented as a statement keyword today, but as runtime expression builtins.

| Built-in | Signature | Description |
|---|---|---|
| `readfile(path)` | `(string) -> string` | Read entire file as a string |
| `args()` | `() -> [string]` | Return command-line arguments as a list |

Implementation: handle these as special cases in `parse_factor` (like `print`) OR as pre-bound `Value::Function` entries in the root environment before `eval` runs.

### 9. `to_string` / `to_int` Conversions
Needed for printing ints in string context and parsing grid coordinates.

| Built-in | Signature |
|---|---|
| `to_string(x)` | `(int \| bool) -> string` |
| `to_int(s)` | `(string) -> int` |

Can be pre-bound functions in the root environment, same approach as `readfile`/`args`.

---

## Project Limitations (0.1.0 Scope)

The following are deliberate shortcuts for 0.1.0 that will be revisited in later releases:

- **`readfile` / `args`** — hard-coded built-ins, not a proper I/O library. A real `std.io` module is a post-0.1.0 concern.
- **No error handling on file read** — `readfile` panics if the file doesn't exist. Proper result types come later.
- **No `break` / `continue`** — not needed for BFS if implemented with a while loop and queue. Can be added later.
- **String indexing returns a single-char string** — there is no `char` type. `str[i]` returns `string`.
- **Mutable list mutation only** — `list.push` / `list.pop` mutate in place. No persistent/immutable collections.

---

# Package Manager Install

Target: `brew install cronyx` (via a personal tap initially, homebrew-core later).

## Steps

### 1. Publish a GitHub Release
- Tag the repository `v0.1.0`
- Build release binaries for:
  - `aarch64-apple-darwin` (Apple Silicon)
  - `x86_64-apple-darwin` (Intel Mac)
- Archive each binary: `cronyx-0.1.0-aarch64-apple-darwin.tar.gz`, etc.
- Attach both archives to the GitHub release

### 2. Create a Homebrew Tap
A tap is a personal formula repository. Users run `brew tap <user>/cronyx` once, then `brew install cronyx`.

- Create a new GitHub repo named `homebrew-cronyx`
- Add a `Formula/cronyx.rb` file:

```ruby
class Cronyx < Formula
  desc "Cronyx programming language compiler/interpreter"
  homepage "https://github.com/<user>/cronyx"
  version "0.1.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/<user>/cronyx/releases/download/v0.1.0/cronyx-0.1.0-aarch64-apple-darwin.tar.gz"
      sha256 "<sha256 of arm binary>"
    else
      url "https://github.com/<user>/cronyx/releases/download/v0.1.0/cronyx-0.1.0-x86_64-apple-darwin.tar.gz"
      sha256 "<sha256 of x86 binary>"
    end
  end

  def install
    bin.install "cronyx"
  end

  test do
    (testpath/"hello.cx").write('print("hello");')
    assert_match "hello", shell_output("#{bin}/cronyx hello.cx")
  end
end
```

### 3. Install Command for Users
```
brew tap <user>/cronyx
brew install cronyx
```

### 4. Future: Linux / Windows
- Linux: `apt` / `snap` / direct binary via install script (`curl | sh`)
- Windows: `choco install cronyx` via Chocolatey
- These are post-0.1.0

---

# Compiler Version Handling

## Design: `cx` + `cxc` Split

Inspired by Cargo/Rustup. Two separate binaries:

| Binary | Role | Analogy |
|---|---|---|
| `cxc` | The compiler/interpreter | `rustc` |
| `cx` | Project manager, version manager | `cargo` + `rustup` combined |

The user always invokes `cx`, never `cxc` directly. `cx` reads the project file, downloads the right `cxc` version if needed, and delegates.

## Project File: `cronyx.toml`

Every Cronyx project has a `cronyx.toml` at the root:

```toml
[project]
name = "maze-solver"
version = "0.1.0"
entry = "main.cx"

[compiler]
cronyx_version = "0.1.0"
```

`cx run` reads `cronyx_version`, checks if that version of `cxc` is installed locally, downloads it if not, and runs it against `entry`.

## Version Storage

Installed compiler versions live in `~/.cronyx/toolchains/`:
```
~/.cronyx/
  toolchains/
    0.1.0/
      bin/cxc
    0.2.0/
      bin/cxc
  active       ← symlink to current global default
```

## CLI Commands

```
cx new <name>          # create a new project with cronyx.toml
cx run                 # run the project using the pinned cxc version
cx build               # compile to output artifact (future)
cx toolchain install <version>   # download a specific cxc version
cx toolchain list                # list installed versions
cx toolchain default <version>   # set global default
cx update              # update cx itself
```

## Version Pinning Behaviour

1. If a `cronyx.toml` is present, always use `cronyx_version` from it
2. If no `cronyx.toml`, use the global default in `~/.cronyx/active`
3. If the required version is not installed, `cx` downloads it automatically (no manual sdkman/nvm step required)
4. Mismatch between `cronyx_version` and installed versions is a hard error with a clear message:
   ```
   error: cronyx 0.2.0 required by cronyx.toml but not installed
   run `cx toolchain install 0.2.0` to install it
   ```

## For 0.1.0

The full `cx` toolchain manager is post-0.1.0 scope. For 0.1.0:
- Ship a single `cronyx` binary (the interpreter, equivalent to `cxc`)
- Install via Homebrew
- No project file yet — just `cronyx main.cx`

Design the binary name and CLI now so the 0.2.0 split into `cx`/`cxc` isn't a breaking change.
