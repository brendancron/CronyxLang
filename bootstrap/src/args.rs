use std::path::PathBuf;

pub struct CliArgs {
    pub source_path: PathBuf,
    pub out_dir: PathBuf,
    pub dump_ast: bool,
    pub dump_typed_ast: bool,
    pub dump_staged: bool,
    pub dump_runtime_ast: bool,
    pub dump_runtime_code: bool,
    pub dump_cps: bool,
    /// Compile to native binary via LLVM instead of interpreting.
    pub compile: bool,
    /// Output binary path when --compile is set (default: a.out).
    pub out_path: Option<PathBuf>,
}

impl CliArgs {
    pub fn parse() -> Result<Self, String> {
        let mut args = std::env::args().skip(1);

        let mut source_path: Option<PathBuf> = None;
        let mut out_dir = PathBuf::from("out");
        let mut dump_ast = false;
        let mut dump_typed_ast = false;
        let mut dump_staged = false;
        let mut dump_runtime_ast = false;
        let mut dump_runtime_code = false;
        let mut dump_cps = false;
        let mut compile = false;
        let mut out_path: Option<PathBuf> = None;

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--dump-ast"          => dump_ast = true,
                "--dump-typed-ast"    => dump_typed_ast = true,
                "--dump-staged"       => dump_staged = true,
                "--dump-runtime-ast"  => dump_runtime_ast = true,
                "--dump-runtime-code" => dump_runtime_code = true,
                "--dump-cps" => dump_cps = true,
                "--compile" => compile = true,
                "--out" => {
                    let path = args.next()
                        .ok_or_else(|| "--out requires a path argument".to_string())?;
                    out_path = Some(PathBuf::from(path));
                }
                "--dump-all" => {
                    dump_ast = true;
                    dump_typed_ast = true;
                    dump_staged = true;
                    dump_runtime_ast = true;
                    dump_runtime_code = true;
                    dump_cps = true;
                }
                "--out-dir" => {
                    let path = args.next()
                        .ok_or_else(|| "--out-dir requires a path argument".to_string())?;
                    out_dir = PathBuf::from(path);
                }
                "--version" | "-V" => {
                    println!("cronyxc {}", env!("CRONYXC_VERSION"));
                    std::process::exit(0);
                }
                "--help" | "-h" => {
                    println!("{}", Self::help_text());
                    std::process::exit(0);
                }
                flag if flag.starts_with("--") => {
                    return Err(format!("unknown flag: {flag}\nrun `cronyxc --help` for usage"));
                }
                path => {
                    if source_path.is_some() {
                        return Err(format!("unexpected argument: {path}"));
                    }
                    source_path = Some(PathBuf::from(path));
                }
            }
        }

        let source_path = source_path
            .ok_or_else(|| Self::help_text().to_string())?;

        Ok(CliArgs {
            source_path,
            out_dir,
            dump_ast,
            dump_typed_ast,
            dump_staged,
            dump_runtime_ast,
            dump_runtime_code,
            dump_cps,
            compile,
            out_path,
        })
    }

    fn help_text() -> &'static str {
        concat!(
            "cronyxc ", env!("CRONYXC_VERSION"), "\n",
            "\n",
            "USAGE:\n",
            "    cronyxc <source.cx> [FLAGS]\n",
            "\n",
            "FLAGS:\n",
            "    --dump-ast            Write meta_ast.txt + meta_ast_graph.txt\n",
            "    --dump-typed-ast      Write meta_ast_typed.txt + type_table.txt\n",
            "    --dump-staged         Write staged_forest.txt + staged_forest_graph.txt\n",
            "    --dump-runtime-ast    Write runtime_ast.txt + runtime_ast_graph.txt\n",
            "    --dump-runtime-code   Write runtime_code.cx (pretty-printed source)\n",
            "    --dump-cps            Write cps_info.txt + cps_code.cx (after CPS transform)\n",
            "    --dump-all            Enable all --dump-* flags\n",
            "    --out-dir <path>      Output directory for debug files (default: ./out)\n",
            "    --compile             Compile to a native binary via LLVM\n",
            "    --out <path>          Output binary path when --compile is set (default: a.out)\n",
            "    -V, --version         Print version and exit\n",
            "    -h, --help            Print this help and exit\n",
        )
    }

    pub fn any_dump(&self) -> bool {
        self.dump_ast
            || self.dump_typed_ast
            || self.dump_staged
            || self.dump_runtime_ast
            || self.dump_runtime_code
            || self.dump_cps
    }
}
