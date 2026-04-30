use super::lexer::tokenize;
use super::meta_ast::{ImportDecl, MetaAst, MetaStmt};
use super::parser::{parse, ParseCtx, ParseError};
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::{fs, io};

/// How a file was pulled into the compilation.
#[derive(Debug, Clone)]
pub enum FileRole {
    /// The program entry point; all top-level statements run.
    Entry,
    /// Explicitly imported via an `import` statement; carries the original decl for binding.
    Explicit(ImportDecl),
    /// Auto-loaded from stdlib (no explicit import needed).
    StdLib(ImportDecl),
}

#[derive(Debug)]
pub struct LoadedFile {
    pub path: PathBuf,
    pub source: String,
    pub ast: MetaAst,
    pub role: FileRole,
    /// Maps AST node ID → (line, col) of the node's first token.
    pub span_table: HashMap<usize, (usize, usize)>,
}

#[derive(Debug)]
pub enum LoadError {
    Io { path: PathBuf, error: io::Error },
    Parse { path: PathBuf, error: String, line: Option<usize>, col: Option<usize> },
}

/// Load all files reachable from `entry` via explicit imports (including `import "dir/*"`).
/// Files in `stdlib_root/lang/` are automatically loaded first (no import needed).
/// The entry file is always first in the result.
pub fn load_compilation_unit(entry: &Path, stdlib_root: &Path) -> Result<Vec<LoadedFile>, LoadError> {
    let entry_canonical = fs::canonicalize(entry)
        .map_err(|e| LoadError::Io { path: entry.to_path_buf(), error: e })?;
    let entry_dir = entry_canonical.parent().unwrap().to_path_buf();

    let mut visited: HashSet<PathBuf> = HashSet::new();
    let mut result: Vec<LoadedFile> = Vec::new();

    // Parse and expand wildcards in the entry file
    let (mut entry_ast, entry_source, entry_spans) = parse_file(&entry_canonical)?;
    expand_wildcard_imports(&mut entry_ast, &entry_dir)
        .map_err(|e| LoadError::Io { path: entry_dir.clone(), error: e })?;
    let explicit_imports = collect_imports(&entry_ast);
    visited.insert(entry_canonical.clone());

    result.push(LoadedFile {
        path: entry_canonical.clone(),
        source: entry_source,
        ast: entry_ast,
        role: FileRole::Entry,
        span_table: entry_spans,
    });

    // BFS over explicit imports with cycle detection.
    // bool = is_stdlib (true → FileRole::StdLib, false → FileRole::Explicit).
    let mut queue: VecDeque<(ImportDecl, PathBuf, bool)> = VecDeque::new();

    // Seed queue with stdlib prelude auto-imports (before user imports).
    // Only core files with no heavy transitive deps are auto-loaded; files like
    // Regex and Toml import automata/parser libs that define conflicting globals.
    const PRELUDE: &[&str] = &["Error", "Fallible", "Math", "Option", "String", "StringBuilder"];
    let lang_dir = stdlib_root.join("lang");
    if lang_dir.is_dir() {
        for &name in PRELUDE {
            let file = lang_dir.join(format!("{name}.cx"));
            if file.exists() {
                let decl = ImportDecl::Qualified { path: format!("lang/{name}") };
                queue.push_back((decl, file, true));
            }
        }
    }

    for decl in explicit_imports {
        let path = resolve_import(&entry_dir, decl.path());
        queue.push_back((decl, path, false));
    }

    while let Some((decl, import_path, is_stdlib)) = queue.pop_front() {
        let canonical = fs::canonicalize(&import_path)
            .map_err(|e| LoadError::Io { path: import_path.clone(), error: e })?;

        if visited.contains(&canonical) {
            continue;
        }
        visited.insert(canonical.clone());

        let (mut ast, source, span_table) = parse_file(&canonical)?;
        let file_dir = canonical.parent().unwrap().to_path_buf();
        expand_wildcard_imports(&mut ast, &file_dir)
            .map_err(|e| LoadError::Io { path: file_dir.clone(), error: e })?;
        let transitive = collect_imports(&ast);

        for tdecl in transitive {
            let tpath = resolve_import(&file_dir, tdecl.path());
            queue.push_back((tdecl, tpath, is_stdlib));
        }

        let role = if is_stdlib { FileRole::StdLib(decl) } else { FileRole::Explicit(decl) };
        result.push(LoadedFile { path: canonical, source, ast, role, span_table });
    }

    Ok(result)
}

fn parse_file(path: &Path) -> Result<(MetaAst, String, HashMap<usize, (usize, usize)>), LoadError> {
    let source = fs::read_to_string(path)
        .map_err(|e| LoadError::Io { path: path.to_path_buf(), error: e })?;
    let tokens = tokenize(&source)
        .map_err(|e| LoadError::Parse { path: path.to_path_buf(), error: format!("{e:?}"), line: None, col: None })?;
    let mut ctx = ParseCtx::new();
    parse(&tokens, &mut ctx)
        .map_err(|e| {
            let (line, col) = parse_error_location(&e);
            LoadError::Parse { path: path.to_path_buf(), error: format!("{e:?}"), line, col }
        })?;
    Ok((ctx.ast, source, ctx.span_table))
}

fn parse_error_location(e: &ParseError) -> (Option<usize>, Option<usize>) {
    match e {
        ParseError::UnexpectedToken { line, col, .. } => (Some(*line), Some(*col)),
        ParseError::UnexpectedEOF { .. } | ParseError::UnterminatedString => (None, None),
    }
}

/// Replace every `Import(Wildcard { path: dir })` node in `ast.sem_root_stmts` with
/// individual `Import(Qualified { path: "dir/stem" })` nodes — one per `.cx` file found
/// in `base_dir/dir`.  Files are sorted for deterministic ordering.
fn expand_wildcard_imports(ast: &mut MetaAst, base_dir: &Path) -> Result<(), io::Error> {
    let original = std::mem::take(&mut ast.sem_root_stmts);

    for id in original {
        let wildcard_dir = match ast.get_stmt(id) {
            Some(MetaStmt::Import(ImportDecl::Wildcard { path })) => Some(path.clone()),
            _ => None,
        };

        if let Some(dir_path) = wildcard_dir {
            ast.remove_stmt(id);
            let dir = base_dir.join(&dir_path);
            let mut files: Vec<PathBuf> = fs::read_dir(&dir)
                .map_err(|e| io::Error::new(e.kind(), format!("{}: {e}", dir.display())))?
                .filter_map(|e| e.ok())
                .filter(|e| e.path().extension().and_then(|x| x.to_str()) == Some("cx"))
                .map(|e| e.path())
                .collect();
            files.sort();
            for file in files {
                let stem = file.file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_string();
                let rel_path = format!("{}/{}", dir_path, stem);
                let new_id = ast.inject_stmt(MetaStmt::Import(ImportDecl::Qualified { path: rel_path }));
                ast.sem_root_stmts.push(new_id);
            }
        } else {
            ast.sem_root_stmts.push(id);
        }
    }

    Ok(())
}

fn collect_imports(ast: &MetaAst) -> Vec<ImportDecl> {
    ast.sem_root_stmts
        .iter()
        .filter_map(|&id| {
            if let Some(MetaStmt::Import(decl)) = ast.get_stmt(id) {
                Some(decl.clone())
            } else {
                None
            }
        })
        .collect()
}

/// Resolve an import path string relative to `base_dir`.
/// Appends `.cx` if not already present.
fn resolve_import(base_dir: &Path, import_path: &str) -> PathBuf {
    let mut p = base_dir.to_path_buf();
    if import_path.ends_with(".cx") {
        p.push(import_path);
    } else {
        p.push(format!("{import_path}.cx"));
    }
    p
}

