open Bootstrap

exception Failed of string

let write path contents =
  match Out_channel.with_open_bin path (fun out -> Out_channel.output_string out contents) with
  | () -> ()
  | exception Sys_error message -> raise (Failed message)

let manifest name =
  Printf.sprintf
    "[package]\nname    = \"%s\"\nversion = \"0.1.0\"\ncronyx  = \"%s\"\n\n[dependencies]\n"
    name
    Release.version

(* Aliased rather than used bare: a package name may carry '-', which is no
   identifier. *)
let example name =
  Printf.sprintf
    "import \"%s\" as pkg;\n\
     \n\
     @test\n\
     fn greets() {\n\
    \    assert(pkg.greeting() == \"Hello, World!\", \"the greeting changed\");\n\
     }\n"
    name

let create ~directory ~name =
  match Manifest.name_problem name with
  | Some problem -> Error problem
  | None when Sys.file_exists directory -> Error (Printf.sprintf "'%s' already exists." directory)
  | None ->
    match
      Sys.mkdir directory 0o755;
      Sys.mkdir (Filename.concat directory "src") 0o755;
      Sys.mkdir (Filename.concat directory "tests") 0o755;
      write (Filename.concat directory Manifest.file_name) (manifest name);
      write
        (Filename.concat directory (Filename.concat "src" "main.cx"))
        "fn greeting(): string {\n\
        \    return \"Hello, World!\";\n\
         }\n\
         \n\
         print(greeting());\n";
      write (Filename.concat directory (Filename.concat "tests" "example.cx")) (example name);
      write (Filename.concat directory ".gitignore") "target/\n"
    with
    | () -> Ok ()
    | exception Failed message -> Error message
    | exception Sys_error message -> Error message
