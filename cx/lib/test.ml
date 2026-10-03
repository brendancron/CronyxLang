(* `cx test`: every `@test` function under `tests/`, each in a process of its
   own, as `nextest` does. Finding them is `std/test/Test`'s: for each file
   this writes a program that reflects the file and has the library generate a
   call per test, compiles it once, asks it for the list, and runs each test in
   a process that calls only that one -- so a crash that is not an effect, an
   index out of range, ends that test and nothing else. *)

open Bootstrap

(* The runner talks to `cx` through the same stream the program prints on, so a
   line it owns is prefixed with a character a program has no reason to write. *)
let marker = "\x1e"

(* The flag the runner spawns itself with. Not in the usage text: it is how the
   two halves of `cx test` talk to each other, and naming it invites someone to
   pass a file that was never written by the half that writes it. *)
let internal = "--internal-run-test"

(* The compiled program reaches each test's process by being written down rather
   than inherited -- Windows has no fork, and `Marshal` of the compiler's own
   types is already how an artifact crosses a process boundary. The tree can go
   this way because it holds no closures: its annotation is `Types.ty`, which is
   constructors and `ref` cells, and `Marshal` keeps the sharing between them
   within one call. The environment is what holds closures, and it is rebuilt on
   the far side. *)
let carrier converted =
  let path = Filename.temp_file "cx-test" ".program" in
  Out_channel.with_open_bin path (fun out -> Marshal.to_channel out converted []);
  path

(* The far side. Nothing else may print on this process's stdout: it is the
   stream the runner parses. *)
let run_one path index name =
  let converted : Ast.cps_stmt list =
    In_channel.with_open_bin path (fun inp -> (Marshal.from_channel inp : Ast.cps_stmt list))
  in
  (* Windows opens stdout in text mode, which would turn every newline the
     runner parses on into a carriage return and a newline. *)
  set_binary_mode_out stdout true;
  let out = print_string in
  let env = Builtins.env ~out in
  Value.define
    env
    Builtins.selected_test
    (Value.Fn { Value.name = Builtins.selected_test; arity = Some 0; apply = (fun _ _ -> Value.Int index) });
  let failed message = out (Printf.sprintf "%s-%s\n%s!%s\n" marker name marker message) in
  (match Pipeline.run env converted with
   | Ok 0 -> ()
   | Ok code -> failed (Printf.sprintf "The test ended the program with exit code %d." code)
   | Error e -> failed e.Diagnostic.message
   | exception e -> failed (Printexc.to_string e));
  flush stdout;
  exit 0

(* One test in a process of its own: what it prints comes back through a pipe,
   and a test whose process ended before it reported is a failure. *)
let in_process ~self carrier (index, name) =
  let reading, writing = Unix.pipe () in
  let child =
    Unix.create_process
      self
      [| self; internal; carrier; string_of_int index; name |]
      Unix.stdin
      writing
      Unix.stderr
  in
  Unix.close writing;
  let channel = Unix.in_channel_of_descr reading in
  set_binary_mode_in channel true;
  let text = In_channel.input_all channel in
  close_in channel;
  ignore (Unix.waitpid [] child);
  let reported tag = marker ^ tag ^ name in
  let contains text piece =
    let n = String.length piece in
    let rec at i = i + n <= String.length text && (String.sub text i n = piece || at (i + 1)) in
    at 0
  in
  if contains text (reported "+") || contains text (reported "-")
  then text
  else text ^ Printf.sprintf "%s-%s\n%s!its process ended before it finished\n" marker name marker

(* Linking mangles a declaration under its package, which is the name to call
   but not the name the author wrote. *)
let shown name =
  match String.rindex_opt name '#' with
  | None -> name
  | Some i -> String.sub name (i + 1) (String.length name - i - 1)

type outcome =
  { name : string
  ; failed : bool
  ; message : string option
  ; output : string list
  }

(* The stream back, split at the runner's own lines: whatever a test printed
   lands between the one that opened it and the one that closed it. *)
let outcomes text =
  let flush acc current = match current with None -> acc | Some o -> o :: acc in
  let done_, current =
    List.fold_left
      (fun (acc, current) line ->
        if not (String.length line > 0 && Char.equal line.[0] '\x1e')
        then
          ( acc
          , Option.map (fun o -> { o with output = line :: o.output }) current )
        else (
          let tag = line.[1] in
          let rest = String.sub line 2 (String.length line - 2) in
          match tag with
          | '>' -> flush acc current, Some { name = rest; failed = false; message = None; output = [] }
          | '+' | '-' ->
            let o =
              match current with
              | Some o -> { o with failed = Char.equal tag '-' }
              | None -> { name = rest; failed = Char.equal tag '-'; message = None; output = [] }
            in
            if Char.equal tag '-' then acc, Some o else o :: acc, None
          | '!' ->
            ( acc
            , Option.map (fun o -> { o with message = Some rest }) current )
          | _ -> acc, current))
      ([], None)
      ((* The final newline terminates the last line rather than opening an
          empty one, and an empty one would be reported as a test's output. *)
       match List.rev (String.split_on_char '\n' text) with
       | "" :: rest -> List.rev rest
       | lines -> List.rev lines)
  in
  List.rev_map
    (fun o -> { o with output = List.rev o.output })
    (flush done_ current)

let matching filter name =
  match filter with
  | None -> true
  | Some needle ->
    let name = shown name in
    let rec at i =
      i + String.length needle <= String.length name
      && (String.equal (String.sub name i (String.length needle)) needle || at (i + 1))
    in
    at 0

(* The whole command, so that what `cx test` prints is what a fixture checks. *)
let report outcomes =
  let out = Buffer.create 256 in
  List.iter
    (fun o ->
      if o.failed
      then (
        Buffer.add_string out (Printf.sprintf "FAIL %s\n" (shown o.name));
        Option.iter (fun m -> Buffer.add_string out (Printf.sprintf "  %s\n" m)) o.message;
        List.iter (fun l -> Buffer.add_string out (Printf.sprintf "  | %s\n" l)) o.output)
      else Buffer.add_string out (Printf.sprintf "ok   %s\n" (shown o.name)))
    outcomes;
  let failed = List.length (List.filter (fun o -> o.failed) outcomes) in
  Buffer.add_string
    out
    (Printf.sprintf "\n%d/%d passed\n" (List.length outcomes - failed) (List.length outcomes));
  Buffer.contents out, failed

(* The package as a test file sees it: its declarations, without the top level
   that `cx run` would execute. A test links the library, not the program --
   otherwise every test file re-runs whatever `main.cx` prints. *)
let declarations program =
  List.filter
    (fun (s : Ast.stmt) ->
      Option.is_some (Loader.declared_name s)
      ||
      match s.Ast.it with
      | `Meta _ | `Derive _ | `Attributed (_, { Ast.it = `Meta _ | `Derive _; _ }) -> true
      | _ -> false)
    program

(* One program per test file, as a Rust integration test is its own crate: a
   file that fails to compile takes only itself down. The program is a file
   this writes under `target/`, importing the test file so it can be
   reflected: the test file's own top-level meta runs when it is, so a test it
   generates is found. *)
let harness ~root file =
  let relative =
    let tests = Loader.normalize (Filename.concat root "tests") ^ "/" in
    let file = Loader.normalize file in
    String.sub file (String.length tests) (String.length file - String.length tests)
  in
  let stem = Filename.chop_suffix relative ".cx" in
  let path = Filename.concat (Filename.concat (Build.target_dir root) "test") (stem ^ ".cx") in
  let rec ensure dir =
    if not (Sys.file_exists dir)
    then (
      ensure (Filename.dirname dir);
      Sys.mkdir dir 0o755)
  in
  ensure (Filename.dirname path);
  (* From the harness back up to the package root, then down to the file. *)
  let depth = List.length (String.split_on_char '/' stem) + 1 in
  let up = String.concat "" (List.init depth (fun _ -> "../")) in
  let source =
    Printf.sprintf
      "import { collect, run_tests } from \"std/test/Test\";\n\
       import \"%stests/%s\" as suite;\n\n\
       meta { collect(moduleof(suite)); }\n\
       run_tests(__test_names(), __test_run);\n"
      up
      stem
  in
  Out_channel.with_open_bin path (fun out -> Out_channel.output_string out source);
  path

let of_file ~root ~manifest ~package program file =
  let ( let* ) = Result.bind in
  let deps =
    (manifest.Manifest.name, { Loader.dep_root = root; compiled = Some package })
    :: Workspace.dependency_roots manifest
  in
  let roots = { Loader.package = root; std = Toolchain.stdlib (); deps } in
  let entry = harness ~root file in
  let* loaded, _ = Pipeline.package ~roots ~seeds:[ entry ] entry in
  (* Both carry the prelude and what it imports, as two linked packages do. *)
  Ok (Build.deduplicated (declarations program @ loaded))

(* What the program lists when no test is chosen: each name, on a line of the
   runner's own. *)
let listed converted =
  let buffer = Buffer.create 256 in
  let env = Builtins.env ~out:(Buffer.add_string buffer) in
  match Pipeline.run env converted with
  | Error e -> Error [ e ]
  | Ok _ ->
    Ok
      (String.split_on_char '\n' (Buffer.contents buffer)
       |> List.filter_map (fun line ->
         let n = String.length marker + 1 in
         if String.length line > n && String.equal (String.sub line 0 n) (marker ^ "?")
         then Some (String.sub line n (String.length line - n))
         else None))

let executed ~self ~root ~filter whole =
  let ( let* ) = Result.bind in
  let* converted = Build.within root (fun () -> Pipeline.linked ~out:(fun _ -> ()) whole) in
  let* names = Build.within root (fun () -> listed converted) in
  let chosen = List.filter (fun (_, name) -> matching filter name) (List.mapi (fun i n -> i, n) names) in
  if chosen = []
  then Ok []
  else (
    flush_all ();
    let ran =
      Build.within root (fun () ->
        let carrier = carrier converted in
        Fun.protect
          ~finally:(fun () -> try Sys.remove carrier with Sys_error _ -> ())
          (fun () -> List.map (in_process ~self carrier) chosen))
    in
    Ok (outcomes (String.concat "" ran)))

(* [self] is the `cx` to spawn a test in, which is not necessarily this process:
   `cx` links the compiler as a library, and the suite in `cx/test` calls this
   in-process. A binary that assumed it was `cx` would spawn the test harness
   and run the whole suite again, once per test. *)
let run ?(mode = Build.unrestricted) ?note ?filter ~self root =
  let ( let* ) = Result.bind in
  (* Resolved before anything chdirs: [Build.within] moves to the package root,
     and a relative path handed in from a build directory does not survive it. *)
  let self =
    if Filename.is_relative self then Filename.concat (Sys.getcwd ()) self else self
  in
  let* artifacts, _ = Build.package ~mode ?note ~out:(fun _ -> ()) root in
  let* manifest = Build.manifest_of root in
  let program = Build.link artifacts in
  let package = List.nth artifacts (List.length artifacts - 1) in
  (* Each file is compiled on its own, so one that does not compile is reported
     with the rest rather than standing in front of them. *)
  let ran, broken =
    List.fold_left
      (fun (seen, broken) file ->
        match
          let* whole = of_file ~root ~manifest ~package program file in
          executed ~self ~root ~filter whole
        with
        | Ok outcomes -> seen @ outcomes, broken
        | Error errors -> seen, broken @ errors)
      ([], [])
      (Build.tests root)
  in
  if broken <> []
  then Error broken
  else (
    match ran with
    | [] -> Ok ("no tests\n", 0)
    | all -> Ok (report all))
