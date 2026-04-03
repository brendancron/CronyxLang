use std::path::PathBuf;

pub struct CliArgs {
    pub source_path: PathBuf,
    pub out_dir: PathBuf,
    pub dump_ast: bool,
    pub dump_typed_ast: bool,
    pub dump_staged: bool,
    pub dump_runtime_ast: bool,
    pub dump_runtime_code: bool,
}

impl CliArgs {
    pub fn parse() -> Self {
        let mut args = std::env::args().skip(1);

        let mut source_path: Option<PathBuf> = None;
        let mut out_dir = PathBuf::from("out");
        let mut dump_ast = false;
        let mut dump_typed_ast = false;
        let mut dump_staged = false;
        let mut dump_runtime_ast = false;
        let mut dump_runtime_code = false;

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--dump-ast"          => dump_ast = true,
                "--dump-typed-ast"    => dump_typed_ast = true,
                "--dump-staged"       => dump_staged = true,
                "--dump-runtime-ast"  => dump_runtime_ast = true,
                "--dump-runtime-code" => dump_runtime_code = true,
                "--dump-all" => {
                    dump_ast = true;
                    dump_typed_ast = true;
                    dump_staged = true;
                    dump_runtime_ast = true;
                    dump_runtime_code = true;
                }
                "--out-dir" => {
                    out_dir = PathBuf::from(
                        args.next().expect("--out-dir requires a path argument"),
                    );
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
                    eprintln!("unknown flag: {flag}");
                    eprintln!("run `cronyxc --help` for usage");
                    std::process::exit(1);
                }
                path => {
                    if source_path.is_some() {
                        eprintln!("unexpected argument: {path}");
                        std::process::exit(1);
                    }
                    source_path = Some(PathBuf::from(path));
                }
            }
        }

        CliArgs {
            source_path: source_path.unwrap_or_else(|| {
                eprintln!("{}", Self::help_text());
                std::process::exit(1);
            }),
            out_dir,
            dump_ast,
            dump_typed_ast,
            dump_staged,
            dump_runtime_ast,
            dump_runtime_code,
        }
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
            "    --dump-all            Enable all --dump-* flags\n",
            "    --out-dir <path>      Output directory for debug files (default: ./out)\n",
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
    }
}
