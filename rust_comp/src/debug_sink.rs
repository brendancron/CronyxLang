use crate::args::CliArgs;
use cronyx::semantics::meta::runtime_ast::RuntimeAst;
use cronyx::semantics::meta::staged_forest::StagedForest;
use cronyx::semantics::types::type_annotated_view::TypeAnnotatedView;
use cronyx::semantics::types::typed_ast::TypeTable;
use cronyx::util::formatter::format_runtime_ast;
use cronyx::util::formatters::tree_formatter::AsTree;
use std::fmt::Debug;
use std::fs::{self, File};
use std::io::Write;
use std::path::PathBuf;

pub struct DebugSink {
    out_dir: Option<PathBuf>,
    dump_ast: bool,
    dump_typed_ast: bool,
    dump_staged: bool,
    dump_runtime_ast: bool,
    dump_runtime_code: bool,
}

impl DebugSink {
    pub fn from_args(args: &CliArgs) -> Self {
        let out_dir = if args.any_dump() {
            fs::create_dir_all(&args.out_dir)
                .unwrap_or_else(|e| panic!("could not create out-dir {}: {e}", args.out_dir.display()));
            Some(args.out_dir.clone())
        } else {
            None
        };

        DebugSink {
            out_dir,
            dump_ast: args.dump_ast,
            dump_typed_ast: args.dump_typed_ast,
            dump_staged: args.dump_staged,
            dump_runtime_ast: args.dump_runtime_ast,
            dump_runtime_code: args.dump_runtime_code,
        }
    }

    /// Write `meta_ast.txt` (tree) and `meta_ast_graph.txt` (debug).
    pub fn dump_ast(&self, ast: &(impl AsTree + Debug)) {
        if !self.dump_ast { return; }
        let Some(ref dir) = self.out_dir else { return };

        ast.format_tree(&mut self.open(dir, "meta_ast.txt"));
        writeln!(self.open(dir, "meta_ast_graph.txt"), "{ast:?}").unwrap();
    }

    /// Write `meta_ast_typed.txt` (annotated tree) and `type_table.txt`.
    pub fn dump_typed_ast(&self, view: TypeAnnotatedView<'_>, table: &TypeTable) {
        if !self.dump_typed_ast { return; }
        let Some(ref dir) = self.out_dir else { return };

        view.format_tree(&mut self.open(dir, "meta_ast_typed.txt"));

        let mut f = self.open(dir, "type_table.txt");
        for (id, ty) in &table.expr_types {
            writeln!(f, "expr {id}: {ty:?}").unwrap();
        }
        for (id, ty) in &table.stmt_types {
            writeln!(f, "stmt {id}: {ty:?}").unwrap();
        }
    }

    /// Write `staged_forest.txt` (tree) and `staged_forest_graph.txt` (debug).
    pub fn dump_staged(&self, forest: &StagedForest) {
        if !self.dump_staged { return; }
        let Some(ref dir) = self.out_dir else { return };

        forest.format_tree(&mut self.open(dir, "staged_forest.txt"));
        writeln!(self.open(dir, "staged_forest_graph.txt"), "{forest:?}").unwrap();
    }

    /// Write `runtime_ast.txt` (tree) and `runtime_ast_graph.txt` (debug).
    pub fn dump_runtime_ast(&self, ast: &RuntimeAst) {
        if !self.dump_runtime_ast { return; }
        let Some(ref dir) = self.out_dir else { return };

        ast.format_tree(&mut self.open(dir, "runtime_ast.txt"));
        writeln!(self.open(dir, "runtime_ast_graph.txt"), "{ast:?}").unwrap();
    }

    /// Write `runtime_code.cx` (pretty-printed generated source).
    pub fn dump_runtime_code(&self, ast: &RuntimeAst) {
        if !self.dump_runtime_code { return; }
        let Some(ref dir) = self.out_dir else { return };

        write!(self.open(dir, "runtime_code.cx"), "{}", format_runtime_ast(ast)).unwrap();
    }

    fn open(&self, dir: &PathBuf, name: &str) -> File {
        File::create(dir.join(name))
            .unwrap_or_else(|e| panic!("could not create {name}: {e}"))
    }
}
