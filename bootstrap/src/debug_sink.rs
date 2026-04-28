use crate::args::CliArgs;
use cronyx::semantics::cps::effect_marker::CpsInfo;
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
    dump_cps: bool,
}

impl DebugSink {
    pub fn from_args(args: &CliArgs) -> Self {
        let out_dir = if args.any_dump() {
            match fs::create_dir_all(&args.out_dir) {
                Ok(()) => Some(args.out_dir.clone()),
                Err(e) => {
                    eprintln!("warning: could not create out-dir {}: {e}", args.out_dir.display());
                    None
                }
            }
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
            dump_cps: args.dump_cps,
        }
    }

    /// Write `meta_ast.txt` (tree) and `meta_ast_graph.txt` (debug).
    pub fn dump_ast(&self, ast: &(impl AsTree + Debug)) {
        if !self.dump_ast { return; }
        let Some(ref dir) = self.out_dir else { return };

        if let Some(mut f) = self.open(dir, "meta_ast.txt") {
            ast.format_tree(&mut f);
        }
        if let Some(mut f) = self.open(dir, "meta_ast_graph.txt") {
            let _ = writeln!(f, "{ast:?}");
        }
    }

    /// Write `meta_ast_typed.txt` (annotated tree) and `type_table.txt`.
    pub fn dump_typed_ast(&self, view: TypeAnnotatedView<'_>, table: &TypeTable) {
        if !self.dump_typed_ast { return; }
        let Some(ref dir) = self.out_dir else { return };

        if let Some(mut f) = self.open(dir, "meta_ast_typed.txt") {
            view.format_tree(&mut f);
        }

        if let Some(mut f) = self.open(dir, "type_table.txt") {
            for (id, ty) in &table.expr_types {
                let _ = writeln!(f, "expr {id}: {ty:?}");
            }
            for (id, ty) in &table.stmt_types {
                let _ = writeln!(f, "stmt {id}: {ty:?}");
            }
        }
    }

    /// Write `staged_forest.txt` (tree) and `staged_forest_graph.txt` (debug).
    pub fn dump_staged(&self, forest: &StagedForest) {
        if !self.dump_staged { return; }
        let Some(ref dir) = self.out_dir else { return };

        if let Some(mut f) = self.open(dir, "staged_forest.txt") {
            forest.format_tree(&mut f);
        }
        if let Some(mut f) = self.open(dir, "staged_forest_graph.txt") {
            let _ = writeln!(f, "{forest:?}");
        }
    }

    /// Write `runtime_ast.txt` (tree) and `runtime_ast_graph.txt` (debug).
    pub fn dump_runtime_ast(&self, ast: &RuntimeAst) {
        if !self.dump_runtime_ast { return; }
        let Some(ref dir) = self.out_dir else { return };

        if let Some(mut f) = self.open(dir, "runtime_ast.txt") {
            ast.format_tree(&mut f);
        }
        if let Some(mut f) = self.open(dir, "runtime_ast_graph.txt") {
            let _ = writeln!(f, "{ast:?}");
        }
    }

    /// Write `runtime_code.cx` (pretty-printed generated source).
    pub fn dump_runtime_code(&self, ast: &RuntimeAst) {
        if !self.dump_runtime_code { return; }
        let Some(ref dir) = self.out_dir else { return };

        if let Some(mut f) = self.open(dir, "runtime_code.cx") {
            let _ = write!(f, "{}", format_runtime_ast(ast));
        }
    }

    /// Write `cps_info.txt` (marked ops/functions) and `cps_code.cx` (transformed source).
    /// Called once before evaluation, after the CPS transform has been applied.
    pub fn dump_cps(&self, info: &CpsInfo, ast: &RuntimeAst) {
        if !self.dump_cps { return; }
        let Some(ref dir) = self.out_dir else { return };

        if let Some(mut f) = self.open(dir, "cps_info.txt") {
            let _ = writeln!(f, "ctl ops:");
            let mut ops: Vec<&String> = info.ctl_ops.iter().collect();
            ops.sort();
            for op in ops {
                let _ = writeln!(f, "  {op}");
            }
            let _ = writeln!(f, "\ncps functions:");
            let mut fns: Vec<&String> = info.cps_fns.iter().collect();
            fns.sort();
            for name in fns {
                let _ = writeln!(f, "  {name}");
            }
        }

        if let Some(mut f) = self.open(dir, "cps_code.cx") {
            let _ = write!(f, "{}", format_runtime_ast(ast));
        }
    }

    fn open(&self, dir: &PathBuf, name: &str) -> Option<File> {
        match File::create(dir.join(name)) {
            Ok(f) => Some(f),
            Err(e) => {
                eprintln!("warning: could not write debug file {name}: {e}");
                None
            }
        }
    }
}
