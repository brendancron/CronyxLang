(* Running a program end to end: what `bootstrap` and `cx run` both do once
   they have parsed their own arguments. *)

type dumps =
  { source : bool
  ; tokens : bool
  ; ast : bool
  ; types : bool
  ; code : bool
  ; processed : bool
  ; show_processed : bool
  ; time : bool
  ; sections : bool
  }

let no_dumps =
  { source = false
  ; tokens = false
  ; ast = false
  ; types = false
  ; code = false
  ; processed = false
  ; show_processed = false
  ; time = false
  ; sections = false
  }

(* Read when the module is initialized, which is as the process starts: total
   time is measured from here, so it includes loading the toolchain. *)
let started = Unix.gettimeofday ()

let ms since = (Unix.gettimeofday () -. since) *. 1000.

(* On stderr, so a program's own output is unchanged. *)
let report_time dumps ~compiled ~ran =
  flush stdout;
  if dumps.sections then prerr_endline "-- time --";
  Printf.eprintf "compile %.1f ms · run %.1f ms · total %.1f ms\n%!" compiled ran (ms started)

let die message =
  prerr_endline message;
  exit 64

let read_source path =
  match Source_map.File.load path with
  | Ok file -> file
  | Error message -> die message

let die_at ~entry errors =
  Render.emit ~entry errors;
  match errors with
  | [] -> exit 70
  | e :: _ -> exit (Diagnostic.exit_code e.Diagnostic.stage)

(* [Loader] scans and parses the entry file again. It happens here first so that
   a mistake in the file the user named is reported as a scan or a parse error
   rather than as a failure to load a module. *)
let dump_front ~entry dumps file =
  let source = Source_map.File.text file in
  if dumps.source
  then (
    print_endline "-- source --";
    print_string source;
    if not (String.length source > 0 && source.[String.length source - 1] = '\n')
    then print_newline ());
  match Scanner.scan_tokens file with
  | Error errors ->
    die_at
      ~entry
      (List.map
         (fun (e : Scanner.error) ->
           Diagnostic.at Diagnostic.Scan e.Scanner.span e.Scanner.message)
         errors)
  | Ok tokens ->
    if dumps.tokens
    then (
      print_endline "-- tokens --";
      List.iter (fun t -> print_endline (Token.to_string t)) tokens);
    (match Parser.parse tokens with
     | Error errors ->
       die_at
         ~entry
         (List.map
            (fun (e : Parser.error) ->
              Diagnostic.at Diagnostic.Parse e.Parser.span e.Parser.message)
            errors)
     | Ok program ->
       if dumps.ast
       then (
         print_endline "-- ast --";
         print_string (Printer.string_of_program program)))

(* A file run on its own is its own package: the directory holding it, plus the
   standard library. *)
(* Everything after the first `--` is the program's, flags included. *)
let split_arguments args =
  let rec go before = function
    | [] -> List.rev before, []
    | "--" :: rest -> List.rev before, rest
    | arg :: rest -> go (arg :: before) rest
  in
  go [] args

let roots_for entry =
  { Loader.package = Filename.dirname entry; std = Toolchain.stdlib (); deps = [] }

(* The marker goes on both streams, so that what precedes it on stderr is a
   compile diagnostic and what follows it is the run's, however the two pipes
   interleave. *)
let run_timed dumps ~entry ~compiled converted =
  if dumps.sections
  then (
    print_endline "-- run --";
    flush stdout;
    prerr_endline "-- run --";
    flush stderr);
  let running = Unix.gettimeofday () in
  let outcome = Pipeline.run (Builtins.env ~out:Builtins.to_stdout) converted in
  if dumps.time then report_time dumps ~compiled ~ran:(ms running);
  match outcome with
  | Ok 0 -> ()
  | Ok code -> exit code
  | Error e -> die_at ~entry [ e ]

(* Spans carry the path [Loader.normalize] made, so the entry is compared in
   that form: on Windows the two spellings differ. *)
let written_code ~entry (written : Ast.program) =
  let entry = Loader.normalize entry in
  Printer.readable_source
    (Source.program
       (List.filter (fun (s : Ast.stmt) -> String.equal (Source_map.Span.path s.Ast.span) entry) written))

let on_written dumps ~entry =
  if dumps.code
  then
    Some
      (fun written ->
        print_endline "-- code --";
        print_string (written_code ~entry written))
  else None

let on_code dumps ~entry processed =
  if dumps.processed || dumps.show_processed
  then (
    print_endline "-- processed --";
    print_string (Printer.cronyx_of_entry ~entry:(Loader.normalize entry) processed);
    if dumps.processed then exit 0)

(* A program already linked: what `cx` hands over once every package has been
   compiled and the artifacts concatenated. *)
let execute_linked ?(dumps = no_dumps) ~entry program =
  let on_types typed =
    if dumps.types
    then (
      print_endline "-- types --";
      print_string (Printer.string_of_processed_program typed))
  in
  let on_code = on_code dumps ~entry in
  let compiling = Unix.gettimeofday () in
  match Pipeline.linked ?on_written:(on_written dumps ~entry) ~on_code ~on_types ~out:Builtins.to_stdout program with
  | Error errors -> die_at ~entry errors
  | Ok converted -> run_timed dumps ~entry ~compiled:(ms compiling) converted

let execute ?(dumps = no_dumps) ?roots entry =
  let roots = match roots with Some roots -> roots | None -> roots_for entry in
  dump_front ~entry dumps (read_source entry);
  let on_code = on_code dumps ~entry in
  let on_types typed =
    if dumps.types
    then (
      print_endline "-- types --";
      print_string (Printer.string_of_processed_program typed))
  in
  let compiling = Unix.gettimeofday () in
  match Pipeline.compile ?on_written:(on_written dumps ~entry) ~on_code ~on_types ~roots ~out:Builtins.to_stdout entry with
  | Error errors -> die_at ~entry errors
  | Ok converted -> run_timed dumps ~entry ~compiled:(ms compiling) converted
