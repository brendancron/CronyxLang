open Bootstrap

let usage =
  "usage: cx <command> [options]\n\n\
  \  new <name>      create a package skeleton\n\
  \  build           compile the package here, and its dependencies\n\
  \  toolchain …     install <version> <binary>, or list\n\
  \  publish         upload the package here to a registry\n\
  \  version         print the toolchain version\n\
  \  run [file.cx]   compile and execute a program, or the package here\n\
  \  test [filter]   run the package's @test functions\n\n\
   options for `build` and `run`:\n\
  \  --locked        fail if the lockfile would change\n\
  \  --offline       no network; the cache or nothing\n\
  \  --frozen        both\n\n\
   options for `run`:\n\
  \  --dump-source   echo the source before running\n\
  \  --dump-tokens   print the token stream\n\
  \  --dump-ast      print the parsed AST\n\
  \  --dump-types    print the type-checked AST\n\
  \  --dump-code     print the program as Cronyx, after metaprocessing\n\n\
  \  -h, --help      show this message"

(* Flags may appear in any order, but exactly one positional path is
   required. *)
let parse_run args =
  let path = ref None in
  let dumps = ref Driver.no_dumps in
  let set_path arg =
    match !path with
    | Some _ -> Driver.die ("unexpected extra argument: " ^ arg ^ "\n" ^ usage)
    | None -> path := Some arg
  in
  List.iter
    (fun arg ->
      match arg with
      | "--dump-source" -> dumps := { !dumps with Driver.source = true }
      | "--dump-tokens" -> dumps := { !dumps with Driver.tokens = true }
      | "--dump-ast" -> dumps := { !dumps with Driver.ast = true }
      | "--dump-types" -> dumps := { !dumps with Driver.types = true }
      | "--dump-code" -> dumps := { !dumps with Driver.code = true }
      | "-h" | "--help" ->
        print_endline usage;
        exit 0
      (* Read by [mode_of], which sees the same list. *)
      | "--locked" | "--offline" | "--frozen" -> ()
      | _ when String.length arg > 1 && arg.[0] = '-' ->
        Driver.die ("unknown option: " ^ arg ^ "\n" ^ usage)
      | _ -> set_path arg)
    args;
  match !path with
  | None -> None, !dumps
  | Some path -> Some path, !dumps

let new_package = function
  | [ name ] ->
    (match Cx.Skeleton.create ~directory:name ~name with
     | Ok () -> Printf.printf "Created package '%s'.\n" name
     | Error message -> Driver.die message)
  | [] -> Driver.die ("new needs a name.\n" ^ usage)
  | _ -> Driver.die ("new takes one name.\n" ^ usage)

let package_root () =
  match Cx.Manifest.find_root (Sys.getcwd ()) with
  | Some root -> root
  | None -> Driver.die "There is no cronyx.toml here or above."

let report entry errors =
  Render.emit ~entry errors;
  exit 65

let mode_of args =
  List.fold_left
    (fun mode arg ->
      match arg with
      | "--locked" -> { mode with Cx.Build.locked = true }
      | "--offline" -> { mode with Cx.Build.offline = true }
      | "--frozen" -> { Cx.Build.locked = true; offline = true }
      (* Read by [parse_run], which sees the same list. *)
      | "--dump-source" | "--dump-tokens" | "--dump-ast" | "--dump-types" | "--dump-code" -> mode
      | _ when String.length arg > 1 && Char.equal arg.[0] '-' ->
        Driver.die ("unknown option: " ^ arg ^ "\n" ^ usage)
      | _ -> mode)
    Cx.Build.unrestricted
    args

let build args =
  let root = package_root () in
  match Cx.Build.package ~mode:(mode_of args) ~out:print_string root with
  | Error errors -> report root errors
  | Ok (artifacts, compiled) ->
    List.iter
      (fun (a : Artifact.t) ->
        Printf.printf
          "%s %s\n"
          (if List.mem a.Artifact.package compiled then "checked" else "cached")
          a.Artifact.package)
      artifacts

let run_package ~mode dumps =
  let root = package_root () in
  match Cx.Build.package ~mode ~out:print_string root with
  | Error errors -> report root errors
  | Ok (artifacts, _) ->
    let entry = Option.value (Cx.Workspace.entry_of root) ~default:root in
    Cx.Build.within root (fun () ->
      Driver.execute_linked ~dumps ~entry (Cx.Build.link artifacts))

(* Each test is one `run` block, so a failure leaves that block and the next
   test still runs: the isolation is the effect system's. *)
let test args =
  let filter =
    match List.filter (fun a -> not (String.length a > 0 && Char.equal a.[0] '-')) args with
    | [] -> None
    | [ one ] -> Some one
    | _ -> Driver.die ("test takes at most one filter.\n" ^ usage)
  in
  let root = package_root () in
  match Cx.Test.run ~mode:(mode_of args) ?filter root with
  | Error errors -> report root errors
  | Ok (rendered, failed) ->
    print_string rendered;
    if failed > 0 then exit 1

let toolchain = function
  | [ "list" ] ->
    (* The one running is a toolchain too, whether or not it was installed
       under ~/.cronyx: a `cx` from a package manager is the whole thing, not a
       launcher for it, so reporting nothing installed would be a lie. *)
    let installed = Cx.Toolchain_store.list () in
    let versions =
      if List.exists (String.equal Release.version) installed
      then installed
      else Release.version :: installed
    in
    List.iter
      (fun version ->
        Printf.printf
          "%s%s\n"
          version
          (if String.equal version Release.version then " (running)" else ""))
      (List.sort compare versions)
  | [ "install"; version; binary ] ->
    (match Cx.Toolchain_store.install ~version ~binary with
     | Error message -> Driver.die message
     | Ok { Cx.Toolchain_store.version; promoted } ->
       Printf.printf
         "Installed %s%s.\n"
         version
         (if promoted then "" else " (an older toolchain, so `cx` stays where it was)"))
  | _ -> Driver.die ("usage: cx toolchain install <version> <binary> | cx toolchain list\n" ^ usage)

(* Before anything else: the package may want a compiler this is not. Reading
   the requirement is the one thing every `cx` must be able to do, whatever age
   it is, so it is read by the frozen reader rather than by the manifest
   parser. *)
let dispatch () =
  match Cx.Manifest.find_root (Sys.getcwd ()) with
  | None -> ()
  | Some root ->
    (match Cx.Dispatch.decide ~running:Release.version ~wanted:(Cx.Dispatch.graph_floor root) with
     | Cx.Dispatch.Run_here -> ()
     | Cx.Dispatch.Hand_to (version, path) -> Cx.Dispatch.hand_to version path Sys.argv
     | Cx.Dispatch.Missing version -> Driver.die (Cx.Dispatch.unavailable version)
     | Cx.Dispatch.Mislabelled version -> Driver.die (Cx.Dispatch.mislabelled version))

let publish () =
  let root = package_root () in
  match Cx.Publish.publish root with
  | Error errors -> report root errors
  | Ok (name, version, checksum) ->
    Printf.printf "Published %s %s (%s).\n" name version checksum

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  if Cx.Dispatch.dispatched args then dispatch ();
  match args with
  | [] -> Driver.die usage
  | ("-h" | "--help") :: _ ->
    print_endline usage;
    exit 0
  | "new" :: args -> new_package args
  | "build" :: args -> build args
  | "toolchain" :: args -> toolchain args
  | "publish" :: _ -> publish ()
  | "test" :: args -> test args
  | "version" :: _ -> print_endline ("cx " ^ Release.version)
  | "run" :: args ->
    (match parse_run args with
     (* No file named: the package here, through its artifacts. *)
     | None, dumps -> run_package ~mode:(mode_of args) dumps
     | Some path, dumps ->
       (match Cx.Workspace.roots_for path with
        | Error errors -> report path errors
        | Ok (roots, _) -> Driver.execute ~dumps ~roots path))
  | command :: _ -> Driver.die ("unknown command: " ^ command ^ "\n" ^ usage)
