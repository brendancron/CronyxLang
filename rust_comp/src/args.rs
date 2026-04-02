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
                flag if flag.starts_with("--") => {
                    eprintln!("unknown flag: {flag}");
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
                eprintln!("usage: cronyx <source.cx> [--dump-ast] [--dump-typed-ast] \
                           [--dump-staged] [--dump-runtime-ast] [--dump-runtime-code] \
                           [--dump-all] [--out-dir <path>]");
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

    pub fn any_dump(&self) -> bool {
        self.dump_ast
            || self.dump_typed_ast
            || self.dump_staged
            || self.dump_runtime_ast
            || self.dump_runtime_code
    }
}
