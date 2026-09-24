(* `cx test`: every `@test` function in the package, each in a process of its
   own, as `nextest` does. A file is compiled once; each test's wrapper runs
   only in the process that is for it, so a crash that is not an effect — an
   index out of range — ends that test and nothing else. Within the process a
   failed assertion is `Assertion::failed`, and `final ctl` means its handler
   cannot resume, so the test's `run` block is left at the failure. *)

open Bootstrap

(* The runner talks to `cx` through the same stream the program prints on, so a
   line it owns is prefixed with a character a program has no reason to write. *)
let marker = "\x1e"

let sp = Source_map.Span.nowhere
let at it = Ast.at sp it
let str text : Ast.expr = at (`Str (Utf8.decode text))
let call name args : Ast.expr = at (`Call (at (`Var name), args))
let stmt it : Ast.stmt = Ast.at sp it
let say e = stmt (`Expr (call "print" [ e ]))
let emit text = say (str (marker ^ text))

let wrapped index (name, _, _) : Ast.stmt =
  let arm =
    { Ast.arm_name = "failed"
    ; arm_kind = Ast.Op_final
    ; arm_params = [ "msg" ]
    ; arm_body =
        [ emit ("-" ^ name)
        ; say (at (`Binop (Ast.Add, str (marker ^ "!"), at (`Var "msg"))))
        ]
    }
  in
  let chosen = at (`Binop (Ast.Equal, call Builtins.selected_test [], at (`Int index))) in
  stmt
    (`If
       ( chosen
       , stmt
           (`Run
              ( [ emit (">" ^ name); stmt (`Expr (call name [])); emit ("+" ^ name) ]
              , [ Ast.Inline { Ast.handled = "Assertion"; arms = [ arm ] } ] ))
       , None ))

(* One test in a process of its own: what it prints comes back through a pipe,
   and a test whose process ended before it reported is a failure. *)
let in_process converted index (name, _, _) =
  let reading, writing = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
    Unix.close reading;
    let channel = Unix.out_channel_of_descr writing in
    let out = output_string channel in
    let env = Builtins.env ~out in
    Value.define
      env
      Builtins.selected_test
      (Value.Fn { Value.name = Builtins.selected_test; arity = Some 0; apply = (fun _ _ -> Value.Int index) });
    let failed message =
      out (Printf.sprintf "%s-%s\n%s!%s\n" marker name marker message)
    in
    (match Pipeline.run env converted with
     | Ok () -> ()
     | Error e -> failed e.Diagnostic.message
     | exception e -> failed (Printexc.to_string e));
    flush channel;
    Unix._exit 0
  | child ->
    Unix.close writing;
    let channel = Unix.in_channel_of_descr reading in
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

(* A test takes no arguments: it is called by name and there is nowhere for one
   to come from. *)
let runnable (name, params, span) =
  if params = [] then Ok (name, params, span)
  else
    Error
      (Diagnostic.at
         Diagnostic.Load
         span
         (Printf.sprintf "'%s' is a test, so it takes no parameters." (shown name)))

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

let matching filter (name, _, _) =
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

let all_runnable found =
  List.fold_left
    (fun acc t ->
      match acc, runnable t with
      | Error e, _ -> Error e
      | Ok _, Error e -> Error [ e ]
      | Ok ts, Ok t -> Ok (t :: ts))
    (Ok [])
    found
  |> Result.map List.rev

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
   file that fails to compile takes only itself down. *)
let of_file ~root ~manifest ~package program file =
  let ( let* ) = Result.bind in
  let deps =
    (manifest.Manifest.name, { Loader.dep_root = root; compiled = Some package })
    :: Workspace.dependency_roots manifest
  in
  let roots =
    { Loader.package = Filename.concat root "tests"; std = Toolchain.stdlib (); deps }
  in
  let* loaded, _ = Pipeline.package ~roots ~seeds:[ file ] file in
  Ok (declarations program @ loaded, loaded)

(* A test is found on the program the walk produced, so one a meta block
   generated is found under the name it was given. [own] says which of them
   this run is for. *)
let executed ~root ~filter ~own program =
  let ( let* ) = Result.bind in
  let buffer = Buffer.create 4096 in
  let out = Buffer.add_string buffer in
  let tests = ref [] in
  let wrap processed =
    let* found =
      all_runnable
        (List.filter (matching filter) (List.filter own (Discover.carrying "test" processed)))
    in
    tests := found;
    Ok (List.mapi wrapped found)
  in
  let* converted =
    Build.within root (fun () -> Pipeline.rooted ~attribute:"test" ~wrap ~out program)
  in
  if !tests = []
  then Ok []
  else (
    flush_all ();
    let ran = Build.within root (fun () -> List.mapi (in_process converted) !tests) in
    Ok (outcomes (String.concat "" ran)))

let run ?(mode = Build.unrestricted) ?filter root =
  let ( let* ) = Result.bind in
  let* artifacts, _ = Build.package ~mode ~out:(fun _ -> ()) root in
  let* manifest = Build.manifest_of root in
  let program = Build.link artifacts in
  let package = List.nth artifacts (List.length artifacts - 1) in
  (* Inline tests run in the whole program: they are part of it, and reach what
     the package does not export. *)
  let* inline = executed ~root ~filter ~own:(fun _ -> true) program in
  (* Each file is compiled on its own, so one that does not compile is reported
     with the rest rather than standing in front of them. *)
  let from_files, broken =
    List.fold_left
      (fun (seen, broken) file ->
        let ran =
          let* whole, _ = of_file ~root ~manifest ~package program file in
          (* Only this file's own tests: the package's inline ones are in
             [whole] too, and have already run. *)
          let here = Loader.normalize file in
          executed
            ~root
            ~filter
            ~own:(fun (_, _, span) -> String.equal (Source_map.Span.path span) here)
            whole
        in
        match ran with
        | Ok outcomes -> seen @ outcomes, broken
        | Error errors -> seen, broken @ errors)
      ([], [])
      (Build.tests root)
  in
  if broken <> []
  then Error broken
  else (
    match inline @ from_files with
    | [] -> Ok ("no tests\n", 0)
    | all -> Ok (report all))
