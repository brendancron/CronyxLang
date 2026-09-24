(* Manifest fixtures live in cx/test/manifests: a .toml with a .ok holding what
   the tool read out of it, or with a .err holding one `[line:col] message` per
   diagnostic. Listed explicitly, so the lists record what is covered. *)

open Bootstrap

let accepted = [ "minimal"; "deps"; "comments"; "dotted"; "registry_dep" ]

let rejected =
  [ "unknown_top_key"
  ; "unknown_package_key"
  ; "missing_name"
  ; "missing_cronyx"
  ; "partial_version"
  ; "leading_zero"
  ; "version_not_string"
  ; "bad_name"
  ; "dep_unknown_key"
  ; "dep_missing_path"
  ; "duplicate_key"
  ; "unterminated_string"
  ; "trailing_junk"
  ]

(* Package fixtures live in cx/test/packages: a directory holding a manifest,
   with an expected.txt of what it prints or an expected.err of the diagnostics
   reading it produced. *)
let packages =
  [ "two_packages/app"; "uses_std"; "same_unit_name"; "generic_dep"; "reads_data" ]
let bad_packages =
  [ "reaches_out"; "claims_std"; "overlapping_impls"; "version_conflict"; "needs_future_compiler" ]

(* Run through `cx test` rather than `cx run`: the expectation is the report,
   not what the program prints. *)
let test_packages = [ "tested"; "bad_test"; "tests_dir"; "generated_tests"; "crashing_test" ]

let repo_root () =
  let marker = Filename.concat "cx" (Filename.concat "test" "manifests") in
  let rec up dir =
    if Sys.file_exists (Filename.concat dir marker)
    then Some dir
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else up parent)
  in
  match Sys.getenv_opt "CRONYX_REPO_ROOT" with
  | Some dir -> Some dir
  | None -> up (Sys.getcwd ())

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let normalize s = String.trim s

(* An expectation that names the running compiler would otherwise have to be
   edited by hand on every version bump — and the release script runs this
   suite after setting the version, so the bump would always fail here. *)
let expectation path =
  let text = read_file path in
  let needle = "{compiler}" in
  let width = String.length needle in
  let out = Buffer.create (String.length text) in
  let i = ref 0 in
  while !i < String.length text do
    if !i + width <= String.length text && String.equal (String.sub text !i width) needle
    then (
      Buffer.add_string out Release.version;
      i := !i + width)
    else (
      Buffer.add_char out text.[!i];
      incr i)
  done;
  Buffer.contents out

let summary (m : Cx.Manifest.t) =
  String.concat
    "\n"
    ([ Printf.sprintf "name = %s" m.Cx.Manifest.name
     ; Printf.sprintf "version = %s" (Cx.Version.to_string m.Cx.Manifest.version)
     ; Printf.sprintf "cronyx = %s" (Cx.Version.to_string m.Cx.Manifest.cronyx)
     ]
     @ List.map
         (fun (d : Cx.Manifest.dependency) ->
           match d.Cx.Manifest.source with
           | Cx.Manifest.Path path -> Printf.sprintf "dep %s = path %s" d.Cx.Manifest.name path
           | Cx.Manifest.Registry requirement ->
             Printf.sprintf
               "dep %s = registry %s"
               d.Cx.Manifest.name
               (Cx.Requirement.render requirement))
         m.Cx.Manifest.dependencies)

(* A diagnostic about a file other than the entry renders that file's path, and
   here that path is absolute. The fixtures are read on more than one machine,
   so the repo root comes back off. *)
let relative root text =
  let prefix = root ^ "/" in
  let width = String.length prefix in
  let buffer = Buffer.create (String.length text) in
  let i = ref 0 in
  while !i < String.length text do
    if !i + width <= String.length text && String.equal (String.sub text !i width) prefix
    then i := !i + width
    else (
      Buffer.add_char buffer text.[!i];
      incr i)
  done;
  Buffer.contents buffer

let diagnostics ?(root = "") path errors =
  let render (e : Diagnostic.error) =
    Printf.sprintf "%s %s" (Ast.locate ~entry:path e.Diagnostic.span) e.Diagnostic.message
  in
  let text = String.concat "\n" (List.map render errors) in
  if String.equal root "" then text else relative root text

let compare_case name ~expected ~actual =
  if String.equal (normalize expected) (normalize actual)
  then (
    Printf.printf "ok   %s\n" name;
    true)
  else (
    Printf.printf
      "FAIL %s\n  --- expected ---\n%s\n  --- actual ---\n%s\n"
      name
      (normalize expected)
      (normalize actual);
    false)

let run_accepted dir name =
  let path = Filename.concat dir (name ^ ".toml") in
  match Cx.Manifest.load path with
  | Error errors ->
    Printf.printf "FAIL manifest/%s\n  %s\n" name (diagnostics path errors);
    false
  | Ok manifest ->
    compare_case ("manifest/" ^ name) ~expected:(read_file (Filename.concat dir (name ^ ".ok"))) ~actual:(summary manifest)

let run_rejected dir name =
  let path = Filename.concat dir (name ^ ".toml") in
  match Cx.Manifest.load path with
  | Ok _ ->
    Printf.printf "FAIL manifest/%s\n  expected a diagnostic, but the manifest was read\n" name;
    false
  | Error errors ->
    compare_case
      ("manifest/" ^ name)
      ~expected:(read_file (Filename.concat dir (name ^ ".err")))
      ~actual:(diagnostics path errors)

(* A fixture no list names is a failure of its own, the way it is for the
   compiler's suite. *)
let unclaimed dir =
  let claimed = Hashtbl.create 32 in
  List.iter (fun name -> Hashtbl.replace claimed name ()) (accepted @ rejected);
  Sys.readdir dir
  |> Array.to_list
  |> List.filter_map (fun entry ->
    if Filename.check_suffix entry ".toml"
    then (
      let name = Filename.remove_extension entry in
      if Hashtbl.mem claimed name then None else Some name)
    else None)
  |> List.sort String.compare

let run_partition dir =
  match unclaimed dir with
  | [] ->
    Printf.printf "ok   every manifest fixture is claimed by a list\n";
    true
  | missing ->
    Printf.printf
      "FAIL manifest fixtures no list names, so nothing runs them:\n%s\n"
      (String.concat "\n" (List.map (fun name -> "  " ^ name) missing));
    false

(* The table in the design doc, which is what a reader recognises from Cargo
   and therefore the thing that must not drift. *)
let requirements =
  [ "1.4", ">=1.4.0, <2.0.0"
  ; "^1.4", ">=1.4.0, <2.0.0"
  ; "^1.4.2", ">=1.4.2, <2.0.0"
  ; "^1", ">=1.0.0, <2.0.0"
  ; "~1.4", ">=1.4.0, <1.5.0"
  ; "~1.4.2", ">=1.4.2, <1.5.0"
  ; "~1", ">=1.0.0, <2.0.0"
  ; "=1.4.2", "=1.4.2"
  ; ">=1, <2", ">=1.0.0, <2.0.0"
  ; "0.4", ">=0.4.0, <0.5.0"
  ; "0.4.2", ">=0.4.2, <0.5.0"
  ; "0.0.3", ">=0.0.3, <0.0.4"
  ; "0.0", ">=0.0.0, <0.1.0"
  ; "0", ">=0.0.0, <1.0.0"
  ]

let run_requirement (written, expected) =
  match Cx.Requirement.of_string written with
  | Error message ->
    Printf.printf "FAIL requirement %s\n  %s\n" written message;
    false
  | Ok r ->
    let actual = Cx.Requirement.render r in
    if String.equal actual expected
    then (
      Printf.printf "ok   requirement %s\n" written;
      true)
    else (
      Printf.printf "FAIL requirement %s\n  expected %s\n  actual   %s\n" written expected actual;
      false)

let membership =
  [ "^1.4", "1.4.0", true
  ; "^1.4", "1.9.9", true
  ; "^1.4", "2.0.0", false
  ; "^1.4", "1.3.9", false
  ; "0.4", "0.5.0", false
  ; "0.0.3", "0.0.4", false
    (* A pre-release is only visible to a requirement that names one at the same
       version, or `^1.0` selects `2.0.0-rc1`. *)
  ; "^1.0", "2.0.0-rc1", false
  ; "^1.0", "1.5.0-rc1", false
  ; ">=1.0.0-rc1, <2", "1.0.0-rc1", true
  ]

let run_membership (written, version, expected) =
  match Cx.Requirement.of_string written, Cx.Version.of_string version with
  | Ok r, Ok v ->
    let actual = Cx.Requirement.satisfies r v in
    if Bool.equal actual expected
    then (
      Printf.printf "ok   %s %s %s\n" version (if expected then "satisfies" else "misses") written;
      true)
    else (
      Printf.printf "FAIL %s against %s: expected %b\n" version written expected;
      false)
  | Error message, _ | _, Error message ->
    Printf.printf "FAIL %s against %s\n  %s\n" version written message;
    false

(* The ordering from the SemVer specification, which is the one place a
   hand-rolled comparison usually goes wrong. *)
let ordering =
  [ "1.0.0-alpha"
  ; "1.0.0-alpha.1"
  ; "1.0.0-alpha.beta"
  ; "1.0.0-beta"
  ; "1.0.0-beta.2"
  ; "1.0.0-beta.11"
  ; "1.0.0-rc.1"
  ; "1.0.0"
  ; "1.0.1"
  ; "1.1.0"
  ; "2.0.0"
  ]

let run_ordering () =
  let parsed = List.map (fun text -> text, Cx.Version.of_string text) ordering in
  let ok = ref true in
  List.iteri
    (fun i (text, v) ->
      List.iteri
        (fun j (other, w) ->
          match v, w with
          | Ok v, Ok w ->
            let expected = Int.compare i j in
            let actual = Int.compare (Cx.Version.compare v w) 0 in
            if actual <> expected
            then (
              Printf.printf "FAIL ordering %s vs %s: expected %d, got %d\n" text other expected actual;
              ok := false)
          | Error message, _ | _, Error message ->
            Printf.printf "FAIL ordering %s\n  %s\n" text message;
            ok := false)
        parsed)
    parsed;
  if !ok then Printf.printf "ok   pre-release ordering\n";
  !ok

let interpret roots entry =
  let buf = Buffer.create 256 in
  let out = Buffer.add_string buf in
  match Pipeline.compile ~roots ~out entry with
  | Error errors -> Error errors
  | Ok converted ->
    (match Pipeline.run (Builtins.env ~out) converted with
     | Ok () -> Ok (Buffer.contents buf)
     | Error e -> Error [ e ])

let rec remove path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun entry -> remove (Filename.concat path entry)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path

(* Every `target/` under the fixture tree, so a run starts from no artifacts at
   all and the first build is the one that writes them. *)
let clean dir =
  let rec walk path =
    if Sys.is_directory path
    then
      Array.iter
        (fun entry ->
          let child = Filename.concat path entry in
          if String.equal entry "target" then remove child else walk child)
        (Sys.readdir path)
  in
  walk dir

(* Through artifacts: every package compiled to a file, the files concatenated,
   and the result run. *)
let built root =
  let buf = Buffer.create 256 in
  let out = Buffer.add_string buf in
  match Cx.Build.package ~out root with
  | Error errors -> Error errors
  | Ok (artifacts, _) ->
    (match Cx.Build.within root (fun () -> Pipeline.linked ~out (Cx.Build.link artifacts)) with
     | Error errors -> Error errors
     | Ok converted ->
       (match Pipeline.run (Builtins.env ~out) converted with
        | Ok () -> Ok (Buffer.contents buf)
        | Error e -> Error [ e ]))

(* Built from nothing, then built again over the artifacts the first run left.
   Both have to agree with the expectation, which is what makes `target/` a
   cache rather than part of the program. *)
let package_case dir name =
  let root = Filename.concat dir name in
  let expected = expectation (Filename.concat root "expected.txt") in
  clean dir;
  match built root, built root with
  | Ok cold, Ok warm ->
    compare_case ("package/" ^ name) ~expected ~actual:cold
    && compare_case ("package/" ^ name ^ " (again)") ~expected ~actual:warm
  | Error errors, _ | _, Error errors ->
    Printf.printf "FAIL package/%s\n  %s\n" name (diagnostics ~root:dir root errors);
    false

let test_package_case dir name =
  let root = Filename.concat dir name in
  let failing = Filename.concat root "expected.err" in
  clean dir;
  match Cx.Test.run root, Sys.file_exists failing with
  | Error errors, true ->
    compare_case
      ("test/" ^ name)
      ~expected:(expectation failing)
      ~actual:(diagnostics ~root:dir root errors)
  | Error errors, false ->
    Printf.printf "FAIL test/%s\n  %s\n" name (diagnostics ~root:dir root errors);
    false
  | Ok (rendered, _), false ->
    compare_case
      ("test/" ^ name)
      ~expected:(expectation (Filename.concat root "expected.txt"))
      ~actual:rendered
  | Ok _, true ->
    Printf.printf "FAIL test/%s\n  expected the diagnostics in expected.err\n" name;
    false

let bad_package_case dir name =
  let root = Filename.concat dir name in
  let expected = expectation (Filename.concat root "expected.err") in
  let rejected path errors =
    compare_case ("package/" ^ name) ~expected ~actual:(diagnostics ~root:dir path errors)
  in
  clean dir;
  match built root with
  | Error errors -> rejected (Option.value (Cx.Workspace.entry_of root) ~default:root) errors
  | Ok _ ->
    Printf.printf "FAIL package/%s\n  expected a diagnostic, but it ran\n" name;
    false

(* A package fixture no list names is a failure of its own, as with the
   manifests. *)
let unclaimed_packages dir =
  let claimed = Hashtbl.create 8 in
  List.iter
    (fun name -> Hashtbl.replace claimed name ())
    (packages @ bad_packages @ test_packages);
  let rec walk prefix =
    let full = if String.equal prefix "" then dir else Filename.concat dir prefix in
    Sys.readdir full
    |> Array.to_list
    |> List.sort String.compare
    |> List.concat_map (fun entry ->
      let name = if String.equal prefix "" then entry else Filename.concat prefix entry in
      let path = Filename.concat dir name in
      if not (Sys.is_directory path)
      then []
      else if Sys.file_exists (Filename.concat path Cx.Manifest.file_name)
      then
        if Sys.file_exists (Filename.concat path "expected.txt")
           || Sys.file_exists (Filename.concat path "expected.err")
        then if Hashtbl.mem claimed name then [] else [ name ]
        else []
      else walk name)
  in
  walk ""

let run_package_partition dir =
  match unclaimed_packages dir with
  | [] ->
    Printf.printf "ok   every package fixture is claimed by a list\n";
    true
  | missing ->
    Printf.printf
      "FAIL package fixtures no list names, so nothing runs them:\n%s\n"
      (String.concat "\n" (List.map (fun name -> "  " ^ name) missing));
    false

let write path contents =
  Out_channel.with_open_bin path (fun out -> Out_channel.output_string out contents)

let compiled_by root =
  match Cx.Build.package ~out:(fun _ -> ()) root with
  | Error _ -> None
  | Ok (_, compiled) -> Some compiled

let expect_compiled what root expected =
  match compiled_by root with
  | None -> Printf.printf "FAIL %s\n  the build failed\n" what; false
  | Some compiled ->
    if List.equal String.equal compiled expected
    then (
      Printf.printf "ok   %s\n" what;
      true)
    else (
      Printf.printf
        "FAIL %s\n  expected [%s]\n  compiled [%s]\n"
        what
        (String.concat "; " expected)
        (String.concat "; " compiled);
      false)

(* Built once, and then not again: a second build with nothing changed must run
   the compiler over nothing at all. *)
let cache_unchanged dir =
  let root = Filename.concat dir "two_packages/app" in
  clean dir;
  expect_compiled "cache/cold" root [ "greet"; "app" ]
  && expect_compiled "cache/unchanged" root []

(* A `meta` block runs when the program is put together, not when its package
   is compiled, so a file it reads is not an input of the artifact: changing it
   rebuilds nothing, and the next run reads it again. *)
let cache_meta_read dir =
  let root = Filename.concat dir "reads_data" in
  let data = Filename.concat root (Filename.concat "src" "banner.txt") in
  let original = read_file data in
  clean dir;
  let ok =
    expect_compiled "cache/meta cold" root [ "greet"; "reads_data" ]
    && (write data "a different banner\n";
        expect_compiled "cache/meta changed" root [])
  in
  write data original;
  ok

(* An artifact is only readable by the compiler that wrote it, so one that names
   another compiler is not a cache hit but a rebuild. *)
let cache_compiler_version dir =
  let root = Filename.concat dir "two_packages/app" in
  clean dir;
  let ok = expect_compiled "cache/version cold" root [ "greet"; "app" ] in
  let path = Cx.Build.artifact_path root "app" in
  (match Artifact.load path with
   | Ok artifact -> Artifact.save path { artifact with Artifact.compiler = "0.0.0-elsewhere" }
   | Error _ -> ());
  ok && expect_compiled "cache/version changed" root [ "app" ]

(* The dispatch preamble is frozen grammar: every `cx` there will ever be has to
   read the version out of a manifest written for a compiler it has never heard
   of, and say so rather than failing to parse it. *)
let preambles =
  [ "[package]\ncronyx = \"0.1.1\"\n", Some "0.1.1"
  ; "[package]\ncronyx='0.2.0'\n", Some "0.2.0"
  ; "[package]\ncronyx = \"0.1.1\"  # the floor\n", Some "0.1.1"
  ; "package.cronyx = \"0.3.0\"\n", Some "0.3.0"
  ; "# nothing but a comment\n", None
  ; "[package]\nname = \"x\"\n", None
    (* The key is only the key under [package]. *)
  ; "[other]\ncronyx = \"9.9.9\"\n", None
    (* Written for a compiler this one has never met, and still readable. *)
  ; "[package]\ncronyx = \"0.9.0\"\nedition = 2031\ncaps = { net = true }\n\n[profile.release]\nopt = 3\n"
    , Some "0.9.0"
  ]

let run_preamble (text, expected) =
  let actual = Cx.Preamble.required text in
  let show = function Some v -> v | None -> "-" in
  if Option.equal String.equal actual expected
  then (
    Printf.printf "ok   preamble %s\n" (show expected);
    true)
  else (
    Printf.printf "FAIL preamble\n  expected %s\n  actual   %s\n" (show expected) (show actual);
    false)

(* What `cx new` writes is the first Cronyx anyone runs, so it has to run and
   its test has to pass -- checked through the same path `cx run` and `cx test`
   take, rather than by comparing the file to a copy of itself. *)
let skeleton_case () =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) "cx-test-skeleton" in
  remove dir;
  Sys.mkdir dir 0o755;
  let root = Filename.concat dir "hello" in
  match Cx.Skeleton.create ~directory:root ~name:"hello" with
  | Error message ->
    Printf.printf "FAIL skeleton/new\n  %s\n" message;
    false
  | Ok () ->
    let ran =
      match built root with
      | Ok output -> compare_case "skeleton/run" ~expected:"Hello, World!\n" ~actual:output
      | Error errors ->
        Printf.printf "FAIL skeleton/run\n  %s\n" (diagnostics ~root:dir root errors);
        false
    in
    let laid_out =
      let has path = Sys.file_exists (Filename.concat root path) in
      let inline =
        let text = read_file (Filename.concat root "src/main.cx") in
        let rec at i =
          i + 5 <= String.length text
          && (String.equal (String.sub text i 5) "@test" || at (i + 1))
        in
        at 0
      in
      if has "tests/example.cx" && not inline
      then (
        Printf.printf "ok   skeleton/tests directory\n";
        true)
      else (
        Printf.printf
          "FAIL skeleton/tests directory\n  the example test belongs in tests/, not inline\n";
        false)
    in
    let tested =
      match Cx.Test.run root with
      | Ok (rendered, failed) ->
        compare_case "skeleton/test" ~expected:"ok   greets\n\n1/1 passed\n" ~actual:rendered
        && failed = 0
      | Error errors ->
        Printf.printf "FAIL skeleton/test\n  %s\n" (diagnostics ~root:dir root errors);
        false
    in
    remove dir;
    ran && laid_out && tested

(* A test file is compiled against the package rather than into it, so an
   archive that carried one would be shipping something no consumer can build:
   their graph has none of its test-only dependencies. *)
let archive_case dir =
  let files = Cx.Archive.of_directory (Filename.concat dir "tests_dir") in
  let named path = List.exists (fun (p, _) -> String.equal p path) files in
  let carried_tests =
    List.exists (fun (p, _) -> String.starts_with ~prefix:"tests/" p) files
  in
  if named "src/lib.cx" && named "cronyx.toml" && not carried_tests
  then (
    Printf.printf "ok   archive/leaves tests out\n";
    true)
  else (
    Printf.printf
      "FAIL archive/leaves tests out\n  packed: %s\n"
      (String.concat ", " (List.map fst files));
    false)

(* A `cx` runs the job itself when it is new enough, hands it on once when it is
   not, and says where to get one when the machine has none. *)
let dispatches =
  [ "0.1.0", None, "here"
  ; "0.1.0", Some "0.1.0", "here"
  ; "0.2.0", Some "0.1.0", "here"
  ; "0.1.0", Some "9.9.9", "missing"
  ]

(* Installing a toolchain cannot be gated on the toolchain being installed. *)
let dispatched_commands =
  [ [ "run" ], true
  ; [ "build"; "--locked" ], true
  ; [ "test" ], true
  ; [ "publish" ], true
  ; [ "toolchain"; "install"; "0.0.2"; "./cx" ], false
  ; [ "toolchain"; "list" ], false
  ; [ "new"; "hello" ], false
  ; [ "version" ], false
  ; [ "--help" ], false
  ; [], false
  ]

let run_dispatched (args, expected) =
  let actual = Cx.Dispatch.dispatched args in
  let shown = String.concat " " args in
  if Bool.equal actual expected
  then (
    Printf.printf "ok   dispatched %s\n" (if shown = "" then "-" else shown);
    true)
  else (
    Printf.printf
      "FAIL dispatched %s\n  expected %b\n  actual   %b\n"
      shown
      expected
      actual;
    false)

let run_dispatch (running, wanted, expected) =
  let actual =
    match Cx.Dispatch.decide ~running ~wanted with
    | Cx.Dispatch.Run_here -> "here"
    | Cx.Dispatch.Hand_to _ -> "hand"
    | Cx.Dispatch.Missing _ -> "missing"
    | Cx.Dispatch.Mislabelled _ -> "mislabelled"
  in
  if String.equal actual expected
  then (
    Printf.printf "ok   dispatch %s wanting %s\n" running (Option.value wanted ~default:"-");
    true)
  else (
    Printf.printf
      "FAIL dispatch %s wanting %s\n  expected %s\n  actual   %s\n"
      running
      (Option.value wanted ~default:"-")
      expected
      actual;
    false)

(* The lockfile is what says a green build stays green, so it has to be the
   same file every time and `--locked` has to mean what it says. *)
let lockfile_cases dir =
  let root = Filename.concat dir "two_packages/app" in
  let lock = Filename.concat root Cx.Lockfile.file_name in
  clean dir;
  if Sys.file_exists lock then Sys.remove lock;
  let check what ok =
    if ok then Printf.printf "ok   %s\n" what else Printf.printf "FAIL %s\n" what;
    ok
  in
  let build ?(mode = Cx.Build.unrestricted) () =
    match Cx.Build.package ~mode ~out:(fun _ -> ()) root with
    | Ok _ -> true
    | Error _ -> false
  in
  let locked = { Cx.Build.locked = true; offline = false } in
  check "lock/absent under --locked" (not (build ~mode:locked ()))
  && check "lock/written" (build () && Sys.file_exists lock)
  && (let first = read_file lock in
      Sys.remove lock;
      ignore (build ());
      check "lock/byte-identical when written again" (String.equal first (read_file lock)))
  && check "lock/holds under --locked" (build ~mode:locked ())

(* The whole circle: a package published into a registry, then resolved,
   fetched, verified and built by one that has never seen it. The registry is a
   directory rather than a server, so what is exercised here is the client --
   the index, the checksum, the cache and the yank rules -- and not the
   transport. *)
let registry_cases root =
  let dir = Filename.concat root (Filename.concat "cx" (Filename.concat "test" "registry")) in
  let temp = Filename.get_temp_dir_name () in
  let registry = Filename.concat temp "cx-test-registry" in
  let cache = Filename.concat (Filename.concat temp "cx-test-home") "registry" in
  let greet = Filename.concat dir "greet" in
  let app = Filename.concat dir "app" in
  let later = Filename.concat temp "cx-test-greet-1.1.0" in
  remove registry;
  remove cache;
  remove later;
  clean dir;
  Unix.putenv "CRONYX_REGISTRY" registry;
  let lock = Filename.concat app Cx.Lockfile.file_name in
  if Sys.file_exists lock then Sys.remove lock;
  let check what ok =
    if ok then Printf.printf "ok   %s\n" what else Printf.printf "FAIL %s\n" what;
    ok
  in
  let version_of name =
    match Cx.Lockfile.read app with
    | None -> None
    | Some text -> List.assoc_opt name (Cx.Lockfile.pins text)
  in
  (* The same package at a later version, so that a yank has something to fall
     back to. *)
  Cx.Home.ensure later;
  Cx.Archive.into_directory later (Cx.Archive.of_directory greet);
  write
    (Filename.concat later Cx.Manifest.file_name)
    "[package]\nname    = \"greet\"\nversion = \"1.1.0\"\ncronyx  = \"0.0.1\"\n";
  let published = Cx.Publish.publish greet in
  let ok =
    check "registry/publish" (Result.is_ok published)
    && check "registry/publish is once only" (Result.is_error (Cx.Publish.publish greet))
    && check
         "registry/publishing a path dependency fails"
         (Result.is_error (Cx.Publish.publish (Filename.concat dir "pathdep")))
    && check "registry/publish a later version" (Result.is_ok (Cx.Publish.publish later))
    && (match built app with
        | Ok output ->
          check
            "registry/resolves, fetches, verifies and builds"
            (String.equal
               (normalize output)
               (normalize (read_file (Filename.concat app "expected.txt"))))
          && check
               "registry/takes the newest satisfying version"
               (Option.equal Cx.Version.equal (version_of "greet") (Result.to_option (Cx.Version.of_string "1.1.0")))
        | Error _ -> check "registry/resolves, fetches, verifies and builds" false)
    (* Yanked after this build already chose it: the lockfile keeps it, because
       one disclosure breaking every downstream build at once is not what a
       disclosure is for. *)
    && (let index = Cx.Registry_source.release_path registry "greet" "1.1.0" in
        write
          index
          (String.concat
             "\n"
             (String.split_on_char '\n' (read_file index)
              |> List.map (fun line ->
                if String.length line >= 6 && String.equal (String.sub line 0 6) "yanked"
                then "yanked = true"
                else line)));
        Result.is_ok (built app)
        && check
             "registry/a yank leaves a pinned version alone"
             (Option.equal
                Cx.Version.equal
                (version_of "greet")
                (Result.to_option (Cx.Version.of_string "1.1.0"))))
    (* Resolved afresh, the yanked one is skipped. *)
    && (Sys.remove lock;
        Result.is_ok (built app)
        && check
             "registry/a yank is skipped by a new resolution"
             (Option.equal
                Cx.Version.equal
                (version_of "greet")
                (Result.to_option (Cx.Version.of_string "1.0.0"))))
    (* The archive the registry serves is not the archive it promised. *)
    && (remove cache;
        let archive = Cx.Registry_source.archive_path registry "greet" "1.0.0" in
        write archive (read_file archive ^ "tampered");
        check "registry/a bad checksum stops the build" (Result.is_error (built app)))
  in
  Unix.putenv "CRONYX_REGISTRY" "";
  ok

let () =
  (* An empty toolchain directory, so a diagnostic that names what this machine
     has says the same thing on every machine. *)
  Unix.putenv "CRONYX_HOME" (Filename.concat (Filename.get_temp_dir_name ()) "cx-test-home");
  match repo_root () with
  | None ->
    prerr_endline "cannot find the repo root; set CRONYX_REPO_ROOT";
    exit 1
  | Some root ->
    let dir = Filename.concat root (Filename.concat "cx" (Filename.concat "test" "manifests")) in
    let packages_dir =
      Filename.concat root (Filename.concat "cx" (Filename.concat "test" "packages"))
    in
    let results =
      (run_partition dir :: List.map (run_accepted dir) accepted)
      @ List.map (run_rejected dir) rejected
      @ (run_package_partition packages_dir :: List.map (package_case packages_dir) packages)
      @ List.map (bad_package_case packages_dir) bad_packages
      @ List.map (test_package_case packages_dir) test_packages
      @ List.map run_preamble preambles
      @ List.map run_dispatch dispatches
      @ List.map run_dispatched dispatched_commands
      @ [ skeleton_case ()
        ; archive_case packages_dir
        ; registry_cases root
        ; lockfile_cases packages_dir
        ; cache_unchanged packages_dir
        ; cache_meta_read packages_dir
        ; cache_compiler_version packages_dir
        ]
      @ List.map run_requirement requirements
      @ List.map run_membership membership
      @ [ run_ordering () ]
    in
    let passed = List.length (List.filter Fun.id results) in
    let total = List.length results in
    Printf.printf "\n%d/%d passed\n" passed total;
    if passed <> total then exit 1
