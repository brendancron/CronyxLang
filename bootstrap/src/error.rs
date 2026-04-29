use std::collections::HashMap;
use std::io::{IsTerminal, Write};
use std::path::PathBuf;

use crate::frontend::module_loader::LoadError;
use crate::runtime::interpreter::EvalError;
use crate::semantics::meta::meta_process_error::MetaProcessError;
use crate::semantics::types::type_error::{TypeError, TypeErrorKind};

// ── Diagnostic ───────────────────────────────────────────────────────────────

/// A structured, renderable compiler diagnostic.
/// Phase 1: title + optional file path + optional help line.
/// Phase 3: will grow a `Span` and source-line rendering via ariadne.
pub struct Diagnostic {
    pub title: String,
    pub file: Option<PathBuf>,
    pub line: Option<usize>,
    pub col: Option<usize>,
    /// Verbatim source line text (for rendering the inline snippet).
    pub source_line: Option<String>,
    /// Column where the underline starts (1-indexed, same as `col`).
    pub underline_col: Option<usize>,
    /// Number of `~` chars in the underline.
    pub underline_len: usize,
    /// Inline label shown after the underline (e.g. "expected int, found string").
    pub label: Option<String>,
    pub help: Option<String>,
}

impl Diagnostic {
    pub fn new(title: impl Into<String>) -> Self {
        Diagnostic {
            title: title.into(),
            file: None, line: None, col: None,
            source_line: None, underline_col: None, underline_len: 1,
            label: None, help: None,
        }
    }

    pub fn with_file(mut self, path: PathBuf) -> Self {
        self.file = Some(path);
        self
    }

    pub fn with_location(mut self, line: usize, col: usize) -> Self {
        self.line = Some(line);
        self.col = Some(col);
        self
    }

    pub fn with_source(mut self, source_line: String, underline_col: usize, underline_len: usize, label: impl Into<String>) -> Self {
        self.source_line = Some(source_line);
        self.underline_col = Some(underline_col);
        self.underline_len = underline_len.max(1);
        self.label = Some(label.into());
        self
    }

    pub fn with_help(mut self, help: impl Into<String>) -> Self {
        self.help = Some(help.into());
        self
    }

    /// Emit this diagnostic to stderr.
    /// Uses ANSI color codes when stderr is a TTY; plain text otherwise.
    pub fn emit(&self) {
        let stderr = std::io::stderr();
        let color = stderr.is_terminal();
        let mut out = stderr.lock();
        self.write_to(&mut out, color);
    }

    fn write_to(&self, out: &mut impl Write, color: bool) {
        // × title
        if color {
            writeln!(out, "\x1b[1;31m×\x1b[0m \x1b[1m{}\x1b[0m", self.title).ok();
        } else {
            writeln!(out, "× {}", self.title).ok();
        }

        // ┌─ path[:line:col]
        if let Some(path) = &self.file {
            let loc = match (self.line, self.col) {
                (Some(l), Some(c)) => format!("{}:{}:{}", path.display(), l, c),
                _ => path.display().to_string(),
            };
            if color {
                writeln!(out, "  \x1b[36m┌─\x1b[0m {loc}").ok();
            } else {
                writeln!(out, "  ┌─ {loc}").ok();
            }
        }

        // Source snippet:
        //   │
        // N │ <source line>
        //   │      ~~~~~~~ label
        //   │
        if let (Some(src), Some(line_num), Some(ucol)) =
            (&self.source_line, self.line, self.underline_col)
        {
            let line_prefix = format!("{line_num}");
            let pad = line_prefix.len();
            let spaces = " ".repeat(pad);
            let tildes = "~".repeat(self.underline_len);
            // indent before underline: ucol is 1-indexed, so ucol-1 spaces
            let underline_indent = " ".repeat(ucol.saturating_sub(1));

            if color {
                writeln!(out, "  \x1b[36m│\x1b[0m").ok();
                writeln!(out, "{line_prefix} \x1b[36m│\x1b[0m {src}").ok();
                if let Some(lbl) = &self.label {
                    writeln!(out, "{spaces} \x1b[36m│\x1b[0m {underline_indent}\x1b[35m{tildes}\x1b[0m {lbl}").ok();
                } else {
                    writeln!(out, "{spaces} \x1b[36m│\x1b[0m {underline_indent}\x1b[35m{tildes}\x1b[0m").ok();
                }
                writeln!(out, "{spaces} \x1b[36m│\x1b[0m").ok();
            } else {
                writeln!(out, "  │").ok();
                writeln!(out, "{line_prefix} │ {src}").ok();
                if let Some(lbl) = &self.label {
                    writeln!(out, "{spaces} │ {underline_indent}{tildes} {lbl}").ok();
                } else {
                    writeln!(out, "{spaces} │ {underline_indent}{tildes}").ok();
                }
                writeln!(out, "{spaces} │").ok();
            }
        }

        // └─ help: text
        if let Some(help) = &self.help {
            if color {
                writeln!(out, "  \x1b[36m└─ help:\x1b[0m {help}").ok();
            } else {
                writeln!(out, "  └─ help: {help}").ok();
            }
        }
    }
}

fn ice(context: &str) -> Diagnostic {
    Diagnostic::new(format!("internal compiler error: {context}"))
        .with_help("please report this at https://github.com/brendancron/compiler/issues")
}

// ── CompilerError ─────────────────────────────────────────────────────────────

#[derive(Debug)]
pub enum CompilerError {
    Load(LoadError),
    TypeCheck(TypeError),
    Meta(MetaProcessError),
    Eval(EvalError),
    Codegen(String),
    /// A `ctl` op (or a function that transitively performs one) was called
    /// at a point where no matching `with ctl` handler is active.
    EffectNotHandled { op: String },
}

impl CompilerError {
    pub fn emit(&self) {
        self.to_diagnostic().emit();
    }

    pub fn summary(n: usize) -> Diagnostic {
        Diagnostic::new(format!("{n} errors found. Compilation failed."))
    }

    pub fn to_diagnostic(&self) -> Diagnostic {
        match self {
            CompilerError::Load(e) => load_diagnostic(e),
            CompilerError::TypeCheck(e) => type_diagnostic(e),
            CompilerError::Meta(e) => meta_diagnostic(e),
            CompilerError::Eval(e) => eval_diagnostic(e),
            CompilerError::Codegen(msg) => Diagnostic::new(format!("codegen error: {msg}")),
            CompilerError::EffectNotHandled { op } => {
                Diagnostic::new(format!("unhandled effect: '{op}' is called but no handler is active"))
                    .with_help(format!("wrap the call in `run {{ ... }} handle <effect> {{ ctl {op}(...) {{ ... }} }}`"))
            }
        }
    }
}

impl From<LoadError> for CompilerError {
    fn from(e: LoadError) -> Self { CompilerError::Load(e) }
}
impl From<TypeError> for CompilerError {
    fn from(e: TypeError) -> Self { CompilerError::TypeCheck(e) }
}
impl From<MetaProcessError> for CompilerError {
    fn from(e: MetaProcessError) -> Self { CompilerError::Meta(e) }
}
impl From<EvalError> for CompilerError {
    fn from(e: EvalError) -> Self { CompilerError::Eval(e) }
}

// ── Per-error-type conversions ────────────────────────────────────────────────

fn load_diagnostic(e: &LoadError) -> Diagnostic {
    match e {
        LoadError::Io { path, error } => {
            Diagnostic::new(format!("could not read file: {error}"))
                .with_file(path.clone())
        }
        LoadError::Parse { path, error, line, col } => {
            let msg = friendly_parse_error(error);
            let mut d = Diagnostic::new(format!("parse error: {msg}"))
                .with_file(path.clone())
                .with_help("check for mismatched brackets, missing semicolons, or typos");
            if let (Some(l), Some(c)) = (line, col) {
                d = d.with_location(*l, *c);
            }
            d
        }
    }
}

fn type_diagnostic(e: &TypeError) -> Diagnostic {
    match &e.kind {
        TypeErrorKind::UnboundVar(name) => {
            Diagnostic::new(format!("unbound variable '{name}'"))
                .with_help(format!("check for a typo, or declare '{name}' before this line"))
        }
        TypeErrorKind::TypeMismatch { expected, found } => {
            Diagnostic::new("type mismatch")
                .with_help(format!("expected {expected}, found {found}"))
        }
        TypeErrorKind::InvalidReturn => {
            Diagnostic::new("return statement outside of a function")
                .with_help("move this return statement inside a function body")
        }
        TypeErrorKind::Unsupported => {
            ice("unsupported type operation")
        }
        TypeErrorKind::PolymorphicCall(name) => {
            Diagnostic::new(format!("polymorphic call to `{name}` with multiple distinct concrete argument types"))
                .with_help("monomorphization is not yet implemented — call `{name}` with the same argument types at every call site")
        }
    }
}

fn meta_diagnostic(e: &MetaProcessError) -> Diagnostic {
    match e {
        MetaProcessError::UnresolvedSymbol(name) => {
            Diagnostic::new(format!("unresolved symbol '{name}'"))
                .with_help(format!("check that '{name}' is exported and its module is imported"))
        }
        MetaProcessError::CircularDependency(chain) => {
            let msg = match chain.len() {
                0 => "circular dependency detected between modules".to_string(),
                1 => format!("circular dependency detected: {}", chain[0]),
                _ => format!("circular dependency detected: {}", chain.join(" → ")),
            };
            Diagnostic::new(msg)
                .with_help("break the cycle by extracting shared code into a separate module")
        }
        MetaProcessError::EmbedFailed { path, error } => {
            Diagnostic::new(format!("could not embed '{path}': {error}"))
        }
        MetaProcessError::UnknownType(name) => {
            Diagnostic::new(format!("unknown type '{name}'"))
                .with_help("check spelling or add the type declaration")
        }
        MetaProcessError::Unimplemented(feature) => {
            ice(&format!("unimplemented feature: {feature}"))
        }
        MetaProcessError::ExprNotFound(id) => ice(&format!("expression node not found (id={id})")),
        MetaProcessError::StmtNotFound(id) => ice(&format!("statement node not found (id={id})")),
    }
}

fn eval_diagnostic(e: &EvalError) -> Diagnostic {
    match e {
        EvalError::UndefinedVariable(name) => {
            Diagnostic::new(format!("undefined variable '{name}'"))
                .with_help("this should have been caught by the type checker — please report")
        }
        EvalError::NonFunctionCall => {
            Diagnostic::new("attempted to call a non-function value")
        }
        EvalError::ArgumentMismatch => {
            Diagnostic::new("wrong number of arguments in function call")
        }
        EvalError::TypeCheckFailed(inner) => type_diagnostic(inner),
        EvalError::TypeError(_) => {
            Diagnostic::new("runtime type error")
        }
        EvalError::UnknownStructType(name) => {
            Diagnostic::new(format!("unknown struct type '{name}'"))
        }
        EvalError::GenOutsideMetaContext => {
            Diagnostic::new("gen block used outside of a meta context")
                .with_help("gen blocks can only appear inside meta { } or meta fn bodies")
        }
        EvalError::DivisionByZero => Diagnostic::new("division by zero"),
        EvalError::Internal(msg) => ice(&format!("internal error: {msg}")),
        EvalError::IoError(msg) => Diagnostic::new(format!("I/O error: {msg}")),
        EvalError::RuntimeError(msg) => Diagnostic::new(msg.clone())
            .with_help("each element must be a tuple matching the destructuring pattern"),
        EvalError::ExprNotFound(id) => ice(&format!("expression node not found (id={id})")),
        EvalError::StmtNotFound(id) => ice(&format!("statement node not found (id={id})")),
        EvalError::Unimplemented => ice("hit an unimplemented interpreter path"),
        // Internal control-flow signals — should never surface to the user.
        EvalError::EffectAborted
        | EvalError::MultiResumed
        | EvalError::CtlSuspend { .. } => ice("effect control-flow signal escaped the interpreter"),
        EvalError::WithLocation { inner, .. } => eval_diagnostic(inner),
    }
}

// ── Source span enrichment ────────────────────────────────────────────────────

/// Attach source location + inline snippet to a diagnostic, when the error
/// carries a node ID that maps to an entry in the span table.
pub fn enrich_diagnostic(
    diag: Diagnostic,
    error: &CompilerError,
    source: &str,
    spans: &HashMap<usize, (usize, usize)>,
) -> Diagnostic {
    // Runtime errors carry a node ID from eval_expr/eval_stmt wrappers.
    // These IDs come from the same parser-generated span table.
    if let CompilerError::Eval(EvalError::WithLocation { node_id, inner }) = error {
        if let Some(&(line, col)) = spans.get(&node_id.0) {
            let src_line = source_line(source, line);
            let len = token_len_at(&src_line, col);
            return diag
                .with_location(line, col)
                .with_source(src_line, col, len, "here");
        }
        // Compact() remaps node IDs so span table lookup may miss.
        // For RuntimeError (e.g. for-loop tuple mismatch), fall back to
        // scanning for the relevant syntax in the source.
        if matches!(inner.as_ref(), EvalError::RuntimeError(_)) {
            for (i, line_text) in source.lines().enumerate() {
                if line_text.contains("for ((") {
                    let col = line_text.find("for").unwrap_or(0) + 1;
                    return diag.with_location(i + 1, col)
                        .with_source(line_text.to_string(), col, 3, "here");
                }
            }
        }
        return diag;
    }

    // Phase-2 (runtime) type errors carry staged-AST node IDs that don't match
    // the parser's span table.  For UnboundVar we can still locate the token
    // with a source-text search; other Phase-2 errors fall back to file-only.
    if let CompilerError::Eval(EvalError::TypeCheckFailed(te)) = error {
        if let TypeErrorKind::UnboundVar(name) = &te.kind {
            return locate_name_in_source(diag, name, source);
        }
        return diag;
    }

    let te = match error {
        CompilerError::TypeCheck(te) => te,
        _ => return diag,
    };
    let node_id = match te.node_id {
        Some(id) => id,
        None => return diag,
    };
    let &(line, col) = match spans.get(&node_id.0) {
        Some(loc) => loc,
        None => return diag,
    };

    let src_line = source_line(source, line);
    let (label, len) = type_error_snippet(&te.kind, col, &src_line);

    diag.with_location(line, col)
        .with_source(src_line, col, len, label)
}

/// Search `source` for the first whole-word occurrence of `name` and attach
/// location + snippet to `diag`.  Used when we have no span-table entry.
fn locate_name_in_source(diag: Diagnostic, name: &str, source: &str) -> Diagnostic {
    for (line_idx, line_text) in source.lines().enumerate() {
        let mut search_from = 0;
        while let Some(col_0) = line_text[search_from..].find(name) {
            let abs_col = search_from + col_0;
            let before_ok = abs_col == 0
                || !line_text.as_bytes()[abs_col - 1].is_ascii_alphanumeric()
                    && line_text.as_bytes()[abs_col - 1] != b'_';
            let after = abs_col + name.len();
            let after_ok = after >= line_text.len()
                || !line_text.as_bytes()[after].is_ascii_alphanumeric()
                    && line_text.as_bytes()[after] != b'_';
            if before_ok && after_ok {
                let line = line_idx + 1;
                let col = abs_col + 1;
                return diag
                    .with_location(line, col)
                    .with_source(line_text.to_string(), col, name.len(), "not found in this scope");
            }
            search_from = abs_col + 1;
        }
    }
    diag
}

/// Extract the text of line `line` (1-indexed) from `source`.
fn source_line(source: &str, line: usize) -> String {
    source.lines().nth(line.saturating_sub(1)).unwrap_or("").to_string()
}

/// Return (label, underline_len) for inline snippet rendering.
fn type_error_snippet(kind: &TypeErrorKind, col: usize, src_line: &str) -> (String, usize) {
    match kind {
        TypeErrorKind::UnboundVar(name) => {
            (format!("not found in this scope"), name.len())
        }
        TypeErrorKind::TypeMismatch { expected, found } => {
            // Best-effort underline: measure the token at col in the source line.
            let len = token_len_at(src_line, col);
            (format!("expected {expected}, found {found}"), len)
        }
        TypeErrorKind::InvalidReturn => {
            ("not inside a function body".to_string(), 6) // len("return")
        }
        TypeErrorKind::Unsupported => {
            ("here".to_string(), 1)
        }
        TypeErrorKind::PolymorphicCall(name) => {
            (format!("multiple concrete types for `{name}`"), name.len())
        }
    }
}

/// Guess the length of the token starting at column `col` (1-indexed) in `line`.
/// Reads forward while the char is alphanumeric, underscore, quote-delimited, or digit.
fn token_len_at(line: &str, col: usize) -> usize {
    let start = col.saturating_sub(1);
    let chars: Vec<char> = line.chars().collect();
    if start >= chars.len() { return 1; }
    let first = chars[start];
    if first == '"' {
        // string literal: find closing "
        let mut i = start + 1;
        while i < chars.len() && chars[i] != '"' { i += 1; }
        return (i - start + 1).max(1);
    }
    let mut len = 0;
    let mut i = start;
    while i < chars.len() && (chars[i].is_alphanumeric() || chars[i] == '_') {
        len += 1;
        i += 1;
    }
    len.max(1)
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Turn the Debug-formatted parse error string into something readable.
/// e.g. "UnexpectedToken { found: RightParen, expected: Identifier, line: 3, col: 5 }"
///   → "unexpected token 'RightParen', expected 'Identifier'"
fn friendly_parse_error(raw: &str) -> String {
    if raw.contains("UnexpectedToken") {
        let found = raw
            .split("found: ")
            .nth(1)
            .and_then(|s| s.split([',', '}']).next())
            .map(str::trim)
            .unwrap_or("unknown token");
        let expected = raw
            .split("expected: ")
            .nth(1)
            .and_then(|s| s.split([',', '}']).next())
            .map(str::trim)
            .unwrap_or("unknown");
        format!("unexpected token '{found}', expected '{expected}'")
    } else if raw.contains("UnexpectedEOF") {
        let expected = raw
            .split("expected: ")
            .nth(1)
            .and_then(|s| s.split([',', '}']).next())
            .map(str::trim)
            .unwrap_or("unknown");
        format!("unexpected end of file, expected '{expected}'")
    } else {
        raw.to_string()
    }
}
