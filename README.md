# Cronyx

A statically-typed, metaprogramming-first language with Hindley-Milner type inference.

See [docs/Cronyx.md](docs/Cronyx.md) for a language overview.

## Building

```zsh
cd rust_comp
cargo build
```

## Running

```zsh
cargo run -- path/to/file.cx
```

Build artifacts are written to `../out/`.

## Testing

```zsh
cargo test
```

Integration tests live in `tests/` and are registered in `rust_comp/tests/script_integration.rs`.
Each test consists of a `.cx` source file and a corresponding `.txt` file containing the expected output.
