use super::lexer::tokenize;
use super::meta_ast::{ImportDecl, MetaAst, MetaStmt};
use super::parser::{parse, ParseCtx};
use std::collections::{HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::{fs, io};

/// How a file was pulled into the compilation.
#[derive(Debug, Clone)]
pub enum FileRole {
    /// The program entry point; all top-level statements run.
    Entry,
    /// A sibling `.cx` file in the same directory as the entry; only fn/struct/meta collected.
    AutoScope,
    /// Explicitly imported via an `import` statement; carries the original decl for binding.
    Explicit(ImportDecl),
}

#[derive(Debug)]
pub struct LoadedFile {
    pub path: PathBuf,
    pub ast: MetaAst,
    pub role: FileRole,
}

#[derive(Debug)]
pub enum LoadError {
    Io { path: PathBuf, error: io::Error },
    Parse { path: PathBuf, error: String },
}

/// Load all files reachable from `entry`, returning them in BFS discovery order.
/// The entry file is always first; auto-scope siblings are last.
pub fn load_compilation_unit(entry: &Path) -> Result<Vec<LoadedFile>, LoadError> {
    let entry_canonical = fs::canonicalize(entry)
        .map_err(|e| LoadError::Io { path: entry.to_path_buf(), error: e })?;
    let entry_dir = entry_canonical.parent().unwrap().to_path_buf();

    let mut visited: HashSet<PathBuf> = HashSet::new();
    let mut result: Vec<LoadedFile> = Vec::new();

    // Parse entry file
    let entry_ast = parse_file(&entry_canonical)?;
    let explicit_imports = collect_imports(&entry_ast);
    visited.insert(entry_canonical.clone());

    result.push(LoadedFile {
        path: entry_canonical.clone(),
        ast: entry_ast,
        role: FileRole::Entry,
    });

    // BFS over explicit imports with cycle detection
    let mut queue: VecDeque<(ImportDecl, PathBuf)> = VecDeque::new();
    for decl in explicit_imports {
        let path = resolve_import(&entry_dir, decl.path());
        queue.push_back((decl, path));
    }

    while let Some((decl, import_path)) = queue.pop_front() {
        let canonical = fs::canonicalize(&import_path)
            .map_err(|e| LoadError::Io { path: import_path.clone(), error: e })?;

        if visited.contains(&canonical) {
            continue;
        }
        visited.insert(canonical.clone());

        let ast = parse_file(&canonical)?;
        let transitive = collect_imports(&ast);

        let file_dir = canonical.parent().unwrap().to_path_buf();
        for tdecl in transitive {
            let tpath = resolve_import(&file_dir, tdecl.path());
            queue.push_back((tdecl, tpath));
        }

        result.push(LoadedFile { path: canonical, ast, role: FileRole::Explicit(decl) });
    }

    Ok(result)
}

/// Load a compilation unit with same-directory auto-scope enabled.
/// Sibling `.cx` files in the entry file's directory are added as `AutoScope` files
/// (FnDecl/StructDecl/MetaBlock only — no runtime statements).
///
/// NOTE: Do not use this in test harnesses where test files share a directory.
pub fn load_compilation_unit_with_autoscope(entry: &Path) -> Result<Vec<LoadedFile>, LoadError> {
    let entry_canonical = fs::canonicalize(entry)
        .map_err(|e| LoadError::Io { path: entry.to_path_buf(), error: e })?;
    let entry_dir = entry_canonical.parent().unwrap().to_path_buf();

    let mut files = load_compilation_unit(entry)?;
    let visited: std::collections::HashSet<PathBuf> = files.iter().map(|f| f.path.clone()).collect();

    let siblings = glob_cx_files(&entry_dir)
        .map_err(|e| LoadError::Io { path: entry_dir.clone(), error: e })?;

    for sibling in siblings {
        let canonical = fs::canonicalize(&sibling)
            .map_err(|e| LoadError::Io { path: sibling.clone(), error: e })?;
        if visited.contains(&canonical) {
            continue;
        }
        let ast = parse_file(&canonical)?;
        files.push(LoadedFile { path: canonical, ast, role: FileRole::AutoScope });
    }

    Ok(files)
}

fn parse_file(path: &Path) -> Result<MetaAst, LoadError> {
    let source = fs::read_to_string(path)
        .map_err(|e| LoadError::Io { path: path.to_path_buf(), error: e })?;
    let tokens = tokenize(&source)
        .map_err(|e| LoadError::Parse { path: path.to_path_buf(), error: format!("{e:?}") })?;
    let mut ctx = ParseCtx::new();
    parse(&tokens, &mut ctx)
        .map_err(|e| LoadError::Parse { path: path.to_path_buf(), error: format!("{e:?}") })?;
    Ok(ctx.ast)
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

fn glob_cx_files(dir: &Path) -> Result<Vec<PathBuf>, io::Error> {
    let mut files = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) == Some("cx") {
            files.push(path);
        }
    }
    Ok(files)
}
