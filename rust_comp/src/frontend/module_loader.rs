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

/// Load all files reachable from `entry` via explicit imports (including `import "dir/*"`).
/// The entry file is always first.
pub fn load_compilation_unit(entry: &Path) -> Result<Vec<LoadedFile>, LoadError> {
    let entry_canonical = fs::canonicalize(entry)
        .map_err(|e| LoadError::Io { path: entry.to_path_buf(), error: e })?;
    let entry_dir = entry_canonical.parent().unwrap().to_path_buf();

    let mut visited: HashSet<PathBuf> = HashSet::new();
    let mut result: Vec<LoadedFile> = Vec::new();

    // Parse and expand wildcards in the entry file
    let mut entry_ast = parse_file(&entry_canonical)?;
    expand_wildcard_imports(&mut entry_ast, &entry_dir)
        .map_err(|e| LoadError::Io { path: entry_dir.clone(), error: e })?;
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

        let mut ast = parse_file(&canonical)?;
        let file_dir = canonical.parent().unwrap().to_path_buf();
        expand_wildcard_imports(&mut ast, &file_dir)
            .map_err(|e| LoadError::Io { path: file_dir.clone(), error: e })?;
        let transitive = collect_imports(&ast);

        for tdecl in transitive {
            let tpath = resolve_import(&file_dir, tdecl.path());
            queue.push_back((tdecl, tpath));
        }

        result.push(LoadedFile { path: canonical, ast, role: FileRole::Explicit(decl) });
    }

    Ok(result)
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
