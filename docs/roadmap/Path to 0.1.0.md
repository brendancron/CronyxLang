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

---

## Required Language Features

The maze solver drives the entire 0.1.0 feature set. All 9 required features are implemented and covered by integration tests.

| # | Feature | Status | Test |
|---|---|---|---|
| 1 | Comparison operators (`<`, `>`, `<=`, `>=`, `!=`) | ✅ Done | `tests/core/operators/comparison` |
| 2 | Logical operators (`and`, `or`, `!`) | ✅ Done | `tests/core/operators/logical` |
| 3 | While loop | ✅ Done | `tests/core/control/while` |
| 4 | List index access (`list[i]`, `grid[y][x]`) | ✅ Done | `tests/core/lists/index_access` |
| 5 | Index assignment (`list[i] = v`, `grid[y][x] = v`) | ✅ Done | `tests/core/lists/index_assign` |
| 6 | String built-in methods (`.len`, `.split`, `.chars`, `.trim`, `.contains`) | ✅ Done | `tests/core/strings/string_methods` |
| 7 | List built-in methods (`.len`, `.push`, `.pop`, `.contains`) | ✅ Done | `tests/core/lists/list_methods` |
| 8 | `readfile(path)` built-in | ✅ Done | `tests/core/builtins/readfile` |
| 9 | `to_string` / `to_int` conversions | ✅ Done | `tests/core/builtins/conversions` |

Note: `args()` is tabled from integration tests for now. It can be added as a pre-bound builtin using the same pattern as `readfile`.

### Implementation Notes

- Logical operators use keyword forms `and`/`or` (already in the lexer). `&&`/`||` are not lexed.
- `to_string` is typed as polymorphic (`∀α. α -> string`) so it accepts `int`, `bool`, or `string`.
- `readfile` paths are relative to the process working directory (the `rust_comp/` package root when running tests).
- String and list built-in methods dispatch through the existing `DotCall` mechanism in the interpreter — no AST changes needed for new methods.

---

## Project Limitations (0.1.0 Scope)

The following are deliberate shortcuts for 0.1.0 that will be revisited in later releases:

- **`readfile` / `args`** — hard-coded built-ins, not a proper I/O library. A real `std.io` module is a post-0.1.0 concern.
- **No error handling on file read** — `readfile` returns an error string if the file doesn't exist. Proper result types come later.
- **No `break` / `continue`** — not needed for BFS if implemented with a while loop and queue. Can be added later.
- **String indexing returns a single-char string** — there is no `char` type. `str[i]` returns `string`.
- **Mutable list mutation only** — `list.push` / `list.pop` mutate in place. No persistent/immutable collections.
- **Logical operators are keyword-only** — `and`/`or`/`!`. No `&&`/`||` tokens in the lexer.

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

---

# Next Steps to 0.1.0

The language feature work is complete. What remains before shipping 0.1.0:

## 1. Write the Maze Solver

The actual proof-of-concept project. This is the real validation that the language is usable end-to-end.

- Implement BFS over the grid to find the path from `S` to `E`
- Mark the solution path with `.` characters using index assignment
- Read the maze from a file passed as a command-line argument (requires `args()`)
- Print the solved maze to stdout

This will likely surface missing features or rough edges not covered by the unit tests.

## 2. Implement `args()`

Needed by the maze solver to accept the maze file path at the command line. Same pattern as `readfile` — a pre-bound builtin that calls `std::env::args()` in the interpreter and returns a `Value::List` of strings.

## 3. Wire Up the CLI Binary

The current entry point in `main.rs` runs a hardcoded file path. For 0.1.0, the binary needs to:
- Accept a `.cx` file path as the first argument: `cronyx main.cx`
- Exit with a non-zero status code on error
- Print interpreter errors to stderr

## 4. Build Release Binaries

Use GitHub Actions (or build locally) to produce:
- `cronyx-0.1.0-aarch64-apple-darwin`
- `cronyx-0.1.0-x86_64-apple-darwin`

Cross-compile with `cargo build --release --target <triple>`.

## 5. Publish the Homebrew Tap

Follow the Package Manager Install section above. Requires:
- A tagged `v0.1.0` GitHub release with the binary archives attached
- A new `homebrew-cronyx` GitHub repo with the formula

---

# Post-0.1.0 Roadmap

Features deliberately deferred out of 0.1.0 scope:

| Feature | Notes |
|---|---|
| `cx`/`cxc` toolchain split | Version manager + compiler split (see Compiler Version Handling section) |
| `args()` proper | Currently tabled; needed for maze solver |
| `break` / `continue` | Not needed for BFS but useful generally |
| Proper error types | Result/Option types instead of panicking on bad input |
| `std.io` module | Replace `readfile` hardcode with a real I/O library |
| Linux / Windows packaging | `apt`, `snap`, `choco`, install script |
| `&&` / `\|\|` token syntax | Currently `and`/`or` keywords only |
| Tuples | Structural type for multi-value returns |
| Type annotations enforcement | Parser accepts annotations but they are not fully enforced |
| Better error messages | Parser/type errors currently expose internal names |
