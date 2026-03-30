# Path to 0.1.1

## Required Language Features

| # | Feature | Status | Test |
|---|---|---|---|
| 1 | C-style `for` loop (`for (init; cond; incr)`) | ✅ Done | `tests/core/control/for_c` |
| 2 | Tuples (`(a, b)`, `.0` / `.1` access) | ✅ Done | `tests/core/tuples/tuple_basic` |
| 3 | Operator precedence (comparisons above `&&`/`\|\|`) | ✅ Done | `tests/core/operators/precedence` |
| 4 | `&&` / `\|\|` replacing `and` / `or` | ✅ Done | `tests/core/operators/logical_symbols` |
| 5 | Compound assignment: `+=`, `-=`, `++`, `--` | ✅ Done | `tests/core/operators/compound_assign` |
| 6 | Unary minus (`-expr`, negative literals) | ✅ Done | `tests/core/operators/unary_minus` |
| 7 | `!` before indexed expressions (`!arr[i]`) | ✅ Done | `tests/core/operators/not_index` |
| 8 | Windows carriage returns (`\r`) tolerated by lexer | ✅ Done | — |

---

## Feature Details

### 1. C-style `for` loop

Syntax: `for (init; cond; incr) { body }`

- `init`: a `var` declaration or assignment statement (no trailing `;` — the `;` is the separator)
- `cond`: any boolean expression
- `incr`: any statement — `i++`, `i--`, `i += 1`, or `i = i + 1`

```cronyx
for (var i = 0; i < 5; i++) {
    print(i);
}
```

The existing `for (x in list)` form is unchanged.

### 2. Tuples

Create with parentheses, two or more elements. Access fields with `.0`, `.1`, etc. (Rust-style integer field access via dot).

```cronyx
var t = (10, "hello", true);
print(t.0);   // 10
print(t.1);   // hello
print(t.2);   // true
```

Functions can return tuples:

```cronyx
fn pair(a, b) {
    return (a, b);
}
var p = pair(3, 4);
print(p.0 + p.1);   // 7
```

**Implementation notes:**
- New `MetaExpr::Tuple(Vec<usize>)` variant
- `.0` / `.1` access: the parser currently handles `DotAccess { field: String }` — extend to also accept a numeric token after `.` and emit `TupleIndex { object, index: usize }`
- `Value::Tuple(Vec<Value>)` in the interpreter

### 3. Operator Precedence

Current problem: all of `+`, `-`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `and`, `or` are at the same precedence level (both parsed in `parse_expr`), so `a == b and c == d` parses as `((a == b) and c) == d`.

Target precedence table (high → low):

| Level | Operators |
|-------|-----------|
| 1 | `!` (unary prefix) |
| 2 | `*`, `/` |
| 3 | `+`, `-` |
| 4 | `<`, `>`, `<=`, `>=` |
| 5 | `==`, `!=` |
| 6 | `&&` |
| 7 | `\|\|` |

**Implementation note:** Split `parse_expr` into layered `parse_or → parse_and → parse_equality → parse_comparison → parse_addition → parse_term → parse_postfix` functions (standard recursive descent).

### 4. `&&` and `||` replacing `and` / `or`

`&&` and `||` become the canonical logical operators. `and` / `or` are removed from the lexer.

**Implementation note:**
- Add `TokenType::AmpAmp` and `TokenType::PipePipe` to the lexer
- Remove `TokenType::And` / `TokenType::Or` keyword tokens
- The `!` prefix operator already exists and is unchanged

### 5. Compound assignment and increment/decrement

New statement forms:
- `x += expr;`
- `x -= expr;`
- `x++;`
- `x--;`

These desugar to `x = x + expr`, `x = x - expr`, `x = x + 1`, `x = x - 1` respectively.

**Implementation note:**
- Add `TokenType::PlusEqual`, `TokenType::MinusEqual`, `TokenType::PlusPlus`, `TokenType::MinusMinus` to the lexer
- Handle in `parse_stmt` under the `Identifier` branch, checking for these tokens at `pos + 1`
- Emit `MetaStmt::Assign` with the desugared expression (no new AST node needed)

---

## Impact on maze-solver.cx

After 0.1.1, the maze solver can be rewritten much more cleanly:

```cronyx
// Grid init: while + manual counter → C-style for
for (var ri = 0; ri < rows; ri++) { ... }

// BFS neighbor offsets: tuple list instead of string-encoded pairs
var dirs = [(0, 1), (1, 0), (0, -1), (-1, 0)];
for (d in dirs) {
    var nr = cr + d.0;
    var nc = cc + d.1;
    ...
}

// Counter increments: i = i + 1 → i++
// Compound bool conditions: no defensive parens needed
if (nr >= 0 && nr < rows && nc >= 0 && nc < cols) { ... }
```
