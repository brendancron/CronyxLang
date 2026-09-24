(* Running a program end to end: what `bootstrap` and `cx run` both do once
   they have parsed their own arguments. *)

type dumps =
  { source : bool
  ; tokens : bool
  ; ast : bool
  ; types : bool
  ; code : bool
  }

let no_dumps =
  { source = false; tokens = false; ast = false; types = false; code = false }

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
let roots_for entry =
  { Loader.package = Filename.dirname entry; std = Toolchain.stdlib (); deps = [] }

(* A program already linked: what `cx` hands over once every package has been
   compiled and the artifacts concatenated. *)
let execute_linked ?(dumps = no_dumps) ~entry program =
  let on_types typed =
    if dumps.types
    then (
      print_endline "-- types --";
      print_string (Printer.string_of_typed_program typed))
  in
  let on_code processed =
    if dumps.code
    then (
      print_endline "-- code --";
      print_string (Source.program processed))
  in
  match Pipeline.linked ~on_code ~on_types ~out:print_string program with
  | Error errors -> die_at ~entry errors
  | Ok converted ->
    (match Pipeline.run (Builtins.env ~out:print_string) converted with
     | Ok () -> ()
     | Error e -> die_at ~entry [ e ])

let execute ?(dumps = no_dumps) ?roots entry =
  let roots = match roots with Some roots -> roots | None -> roots_for entry in
  dump_front ~entry dumps (read_source entry);
  let on_code processed =
    if dumps.code
    then (
      print_endline "-- code --";
      print_string (Source.program processed))
  in
  let on_types typed =
    if dumps.types
    then (
      print_endline "-- types --";
      print_string (Printer.string_of_typed_program typed))
  in
  match Pipeline.compile ~on_code ~on_types ~roots ~out:print_string entry with
  | Error errors -> die_at ~entry errors
  | Ok converted ->
    (match Pipeline.run (Builtins.env ~out:print_string) converted with
     | Ok () -> ()
     | Error e -> die_at ~entry [ e ])
