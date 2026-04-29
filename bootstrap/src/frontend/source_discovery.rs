use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Module {
    pub path: PathBuf,
    pub imports: Vec<PathBuf>,
}

pub struct SourceDiscovery {
    visited: HashSet<PathBuf>,
    modules: HashMap<PathBuf, Module>,
}

impl SourceDiscovery {
    pub fn new() -> Self {
        Self {
            visited: HashSet::new(),
            modules: HashMap::new(),
        }
    }

    pub fn discover(&mut self, root: PathBuf) -> Result<(), String> {
        let root = fs::canonicalize(&root)
            .map_err(|e| format!("failed to open root file: {e}"))?;
        self.visit(&root)
    }

    fn visit(&mut self, path: &Path) -> Result<(), String> {
        if self.visited.contains(path) {
            return Ok(());
        }
        self.visited.insert(path.to_path_buf());

        let source = fs::read_to_string(path)
            .map_err(|e| format!("failed to read {path:?}: {e}"))?;

        let imports = parse_imports(&source, path)?;

        self.modules.insert(
            path.to_path_buf(),
            Module {
                path: path.to_path_buf(),
                imports: imports.clone(),
            },
        );

        for imp in &imports {
            self.visit(imp)?;
        }

        Ok(())
    }

    pub fn modules(self) -> HashMap<PathBuf, Module> {
        self.modules
    }
}

fn parse_imports(source: &str, base: &Path) -> Result<Vec<PathBuf>, String> {
    let mut imports = Vec::new();

    for line in source.lines() {
        let line = line.trim();

        if let Some(rest) = line.strip_prefix("import ") {
            let name = rest.trim_end_matches(';').trim();

            let mut path = base.parent().unwrap().to_path_buf();
            path.push(format!("{name}.cx"));

            imports.push(
                fs::canonicalize(&path)
                    .map_err(|_| format!("import not found: {path:?}"))?,
            );
        }
    }

    Ok(imports)
}
