(* `cx bench`: every `@bench` function under `benches/`, found and run as `cx
   test` runs a test, each in a process of its own -- here twice, at its size
   and at [factor] times it. One timing says little on a machine shared with
   anything else; how time and memory grow between two sizes says whether a
   call leaks or a loop went quadratic, and that is what a benchmark is held
   to. *)

open Bootstrap

let internal = "--internal-run-bench"
let factor = 4

let source suite =
  Printf.sprintf
    "import { collect_benches, run_benches } from \"std/test/Bench\";\n\
     import \"%s\" as suite;\n\n\
     meta { collect_benches(moduleof(suite)); }\n\
     run_benches(__bench_names(), __bench_plans(), __bench_run);\n"
    suite

let write ~root file = Test.harness ~dir:"benches" ~target:"bench" ~source ~root file

(* The far side. The heap is compacted first so that what the run adds is
   measured from what the program itself needed to be loaded. *)
let run_one path index name size =
  let converted : Ast.cps_stmt list =
    In_channel.with_open_bin path (fun inp -> (Marshal.from_channel inp : Ast.cps_stmt list))
  in
  set_binary_mode_out stdout true;
  let out = print_string in
  let env = Builtins.env ~out in
  let fixed name n = Value.define env name (Value.Fn { Value.name; arity = Some 0; apply = (fun _ _ -> Value.Int n) }) in
  fixed Builtins.selected_test index;
  fixed Builtins.bench_size size;
  let failed message = out (Printf.sprintf "%s-%s\n%s!%s\n" Test.marker name Test.marker message) in
  Gc.compact ();
  let base = (Gc.quick_stat ()).Gc.heap_words in
  let start = Unix.gettimeofday () in
  (match Pipeline.run env converted with
   | Ok 0 ->
     let seconds = Unix.gettimeofday () -. start in
     let words = (Gc.quick_stat ()).Gc.top_heap_words - base in
     out (Printf.sprintf "%s=%f\t%d\n" Test.marker seconds (Int.max 0 words * (Sys.word_size / 8)))
   | Ok code -> failed (Printf.sprintf "The benchmark ended the program with exit code %d." code)
   | Error e -> failed e.Diagnostic.message
   | exception e -> failed (Printexc.to_string e));
  flush stdout;
  exit 0

type sample =
  { seconds : float
  ; bytes : int
  }

let spawn ~self carrier index name size =
  let reading, writing = Unix.pipe () in
  let child =
    Unix.create_process
      self
      [| self; internal; carrier; string_of_int index; name; string_of_int size |]
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
  let lines = String.split_on_char '\n' text in
  let owned tag =
    List.find_map
      (fun line ->
        if String.length line > 1 && Char.equal line.[0] '\x1e' && Char.equal line.[1] tag
        then Some (String.sub line 2 (String.length line - 2))
        else None)
      lines
  in
  match owned '=', owned '!' with
  | _, Some message -> Error message
  | Some measured, None ->
    (match String.split_on_char '\t' measured with
     | [ seconds; bytes ] -> Ok { seconds = float_of_string seconds; bytes = int_of_string bytes }
     | _ -> Error "its process reported a measurement it could not read")
  | None, None -> Error "its process ended before it finished"

type plan =
  { size : int
  ; time : string option
  ; memory : string option
  }

let plan_of text =
  let class_ = function
    | "-" -> None
    | c -> Some c
  in
  match String.split_on_char '\t' text with
  | [ name; size; time; memory ] ->
    Some (name, { size = int_of_string size; time = class_ time; memory = class_ memory })
  | _ -> None

let exponent_of = function
  | "constant" -> 0.0
  | "linear" -> 1.0
  | _ -> 2.0

(* Below these, a run is mostly the process starting and the program loading,
   and a ratio of two such numbers is noise rather than growth. *)
let time_floor = 0.01
let memory_floor = float_of_int (1 lsl 20)

(* How a quantity grew as n^k between the two sizes. *)
let growth floor small large =
  Float.log (Float.max floor large /. Float.max floor small) /. Float.log (float_of_int factor)

(* Half a class of slack: a linear benchmark measured at n^1.3 is still linear,
   and one that leaks per call is n^1 where it said n^0. *)
let within declared measured = measured <= exponent_of declared +. 0.5

type outcome =
  { name : string
  ; failure : string option
  ; detail : string option
  }

let shown_seconds s =
  if s >= 1.0 then Printf.sprintf "%.2fs" s else Printf.sprintf "%.1fms" (s *. 1000.0)

let shown_bytes b = Printf.sprintf "%.1fMB" (float_of_int b /. float_of_int (1 lsl 20))

let judged name plan small large =
  let time = growth time_floor small.seconds large.seconds in
  let memory = growth memory_floor (float_of_int small.bytes) (float_of_int large.bytes) in
  let broken =
    List.filter_map
      (fun (what, declared, measured) ->
        match declared with
        | Some c when not (within c measured) ->
          Some (Printf.sprintf "%s grew as n^%.1f, and it is declared %s" what measured c)
        | _ -> None)
      [ "time", plan.time, time; "memory", plan.memory, memory ]
  in
  { name
  ; failure = (match broken with [] -> None | _ -> Some (String.concat "; " broken))
  ; detail =
      Some
        (Printf.sprintf
           "n=%d: %s %s   n=%d: %s %s   time n^%.1f, memory n^%.1f"
           plan.size
           (shown_seconds small.seconds)
           (shown_bytes small.bytes)
           (plan.size * factor)
           (shown_seconds large.seconds)
           (shown_bytes large.bytes)
           time
           memory)
  }

let measured ~self carrier (index, (name, plan)) =
  match spawn ~self carrier index name plan.size with
  | Error message -> { name; failure = Some message; detail = None }
  | Ok small ->
    (match spawn ~self carrier index name (plan.size * factor) with
     | Error message -> { name; failure = Some message; detail = None }
     | Ok large -> judged name plan small large)

(* The verdict on a line of its own and the numbers on the next, indented, so a
   fixture can hold the one and ignore the other. *)
let report outcomes =
  let out = Buffer.create 256 in
  List.iter
    (fun o ->
      (match o.failure with
       | None -> Buffer.add_string out (Printf.sprintf "ok   %s\n" (Test.shown o.name))
       | Some why -> Buffer.add_string out (Printf.sprintf "FAIL %s\n  %s\n" (Test.shown o.name) why));
      Option.iter (fun d -> Buffer.add_string out (Printf.sprintf "  %s\n" d)) o.detail)
    outcomes;
  let failed = List.length (List.filter (fun o -> Option.is_some o.failure) outcomes) in
  Buffer.add_string
    out
    (Printf.sprintf "\n%d/%d passed\n" (List.length outcomes - failed) (List.length outcomes));
  Buffer.contents out, failed

let executed ~self ~root ~filter whole =
  let ( let* ) = Result.bind in
  let* converted = Build.within root (fun () -> Pipeline.linked ~out:(fun _ -> ()) whole) in
  let* listed = Build.within root (fun () -> Test.listed converted) in
  let plans = List.filter_map plan_of listed in
  let chosen =
    List.filter
      (fun (_, (name, _)) -> Test.matching filter name)
      (List.mapi (fun i p -> i, p) plans)
  in
  if chosen = []
  then Ok []
  else (
    flush_all ();
    Ok
      (Build.within root (fun () ->
         let carrier = Test.carrier converted in
         Fun.protect
           ~finally:(fun () -> try Sys.remove carrier with Sys_error _ -> ())
           (fun () -> List.map (measured ~self carrier) chosen))))

let run ?(mode = Build.unrestricted) ?note ?filter ~self root =
  let ( let* ) = Result.bind in
  let self =
    if Filename.is_relative self then Filename.concat (Sys.getcwd ()) self else self
  in
  let* artifacts, _ = Build.package ~mode ?note ~out:(fun _ -> ()) root in
  let* manifest = Build.manifest_of root in
  let program = Build.link artifacts in
  let package = List.nth artifacts (List.length artifacts - 1) in
  let ran, broken =
    List.fold_left
      (fun (seen, broken) file ->
        match
          let* whole = Test.of_file ~write ~root ~manifest ~package program file in
          executed ~self ~root ~filter whole
        with
        | Ok outcomes -> seen @ outcomes, broken
        | Error errors -> seen, broken @ errors)
      ([], [])
      (Build.benches root)
  in
  if broken <> []
  then Error broken
  else (
    match ran with
    | [] -> Ok ("no benchmarks\n", 0)
    | all -> Ok (report all))
