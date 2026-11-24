open Bootstrap

let usage =
  "usage: bootstrap [options] <file.cx> [-- <arguments>]\n\
  \  --dump-source   echo the source before running\n\
  \  --dump-tokens   print the token stream\n\
  \  --dump-ast      print the parsed AST\n\
  \  --dump-types    print the type-checked AST\n\
  \  --dump-code     print the program as Cronyx, after metaprocessing\n\
  \  --dump-processed  print the entry's own code after metaprocessing, as Cronyx, and stop\n\
  \  --show-processed  the same, then run the program\n\
  \  --time          print compile, run and total time on stderr\n\
  \  --sections      split the output for a tool: just before running, write a\n\
  \                  `-- run --` line on stdout and on stderr. Before it is\n\
  \                  compile time (meta output, diagnostics, `-- processed --`\n\
  \                  and its code); after it is the run. With --time, the\n\
  \                  timing line follows a `-- time --` line on stderr\n\
  \  -h, --help      show this message"

(* Flags may appear in any order, but exactly one positional path is
   required. *)
let parse_args argv =
  let path = ref None in
  let dumps = ref Driver.no_dumps in
  let set_path arg =
    match !path with
    | Some _ -> Driver.die ("unexpected extra argument: " ^ arg ^ "\n" ^ usage)
    | None -> path := Some arg
  in
  Array.iteri
    (fun i arg ->
      if i > 0
      then (
        match arg with
        | "--dump-source" -> dumps := { !dumps with Driver.source = true }
        | "--dump-tokens" -> dumps := { !dumps with Driver.tokens = true }
        | "--dump-ast" -> dumps := { !dumps with Driver.ast = true }
        | "--dump-types" -> dumps := { !dumps with Driver.types = true }
        | "--dump-code" -> dumps := { !dumps with Driver.code = true }
        | "--dump-processed" -> dumps := { !dumps with Driver.processed = true }
        | "--time" -> dumps := { !dumps with Driver.time = true }
      | "--show-processed" -> dumps := { !dumps with Driver.show_processed = true }
      | "--sections" -> dumps := { !dumps with Driver.sections = true }
        | "-h" | "--help" ->
          print_endline usage;
          exit 0
        | _ when String.length arg > 1 && arg.[0] = '-' ->
          Driver.die ("unknown option: " ^ arg ^ "\n" ^ usage)
        | _ -> set_path arg))
    argv;
  match !path with
  | None -> Driver.die usage
  | Some path -> path, !dumps

(* Windows opens these in text mode, which turns every newline into a carriage
   return and a newline. What a compiler prints is compared byte for byte -- by
   the fixture suite, by `scripts/cx-parity.sh`, and by anyone diffing two
   runs -- so it is the same on every platform. *)
let () =
  set_binary_mode_out stdout true;
  set_binary_mode_out stderr true

let () =
  let ours, theirs = Driver.split_arguments (Array.to_list Sys.argv) in
  System.arguments := theirs;
  let path, dumps = parse_args (Array.of_list ours) in
  Driver.execute ~dumps path
