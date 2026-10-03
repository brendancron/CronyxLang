(* What the root hands a program of the OS: its arguments and environment, the
   clocks, entropy, directories and subprocesses. Each answer is a tuple whose
   first part is a status the library turns into an `IoError`: 0 is success,
   then NotFound, Denied and Other. *)

let arguments : string list ref = ref []

let status_of_unix (e : Unix.error) =
  match e with
  | Unix.ENOENT -> 1
  | Unix.EACCES | Unix.EPERM -> 2
  | _ -> 3

let byte_array text = Value.Array (Array.init (String.length text) (fun i -> Value.Byte text.[i]))

let bytes_of (v : Value.value) =
  match v with
  | Value.Array items ->
    Some
      (String.init (Array.length items) (fun i ->
         match items.(i) with
         | Value.Byte c -> c
         | _ -> '\000'))
  | _ -> None

let str text = Value.Str (Utf8.decode text)
let no_message = Value.Str [||]

let text_of (v : Value.value) =
  match v with
  | Value.Str s -> Some (Utf8.encode s)
  | _ -> None

let texts_of (v : Value.value) =
  match v with
  | Value.Array items -> Some (Array.to_list (Array.map (fun v -> Option.value (text_of v) ~default:"") items))
  | _ -> None

let pairs_of (v : Value.value) =
  match v with
  | Value.Array items ->
    Some
      (Array.to_list items
       |> List.filter_map (function
         | Value.Tuple [ Value.Str k; Value.Str v ] -> Some (Utf8.encode k, Utf8.encode v)
         | _ -> None))
  | _ -> None

let failed_unix e = Value.Int (status_of_unix e), str (Unix.error_message e)

(* ---- the environment ---- *)

(* A copy taken once, which setting a variable changes and a subprocess is
   started with. The process's own is never written: nothing in the
   interpreter reads it, and OCaml cannot remove a variable from it. *)
let environment : (string, string) Hashtbl.t Lazy.t =
  lazy
    (let table = Hashtbl.create 64 in
     Array.iter
       (fun entry ->
         match String.index_opt entry '=' with
         (* Windows keeps per-drive directories as `=C:=C:\...`, which are not
            variables anyone set. *)
         | Some 0 | None -> ()
         | Some at ->
           Hashtbl.replace table (String.sub entry 0 at) (String.sub entry (at + 1) (String.length entry - at - 1)))
       (Unix.environment ());
     table)

let variables () =
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) (Lazy.force environment) []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(* ---- time ---- *)

let nanos seconds = Float.to_int (seconds *. 1e9)

(* OCaml's `Unix` has no monotonic clock, so the wall clock is held from going
   backwards instead. *)
let last_instant = ref 0

let instant () =
  let now = nanos (Unix.gettimeofday ()) in
  if now > !last_instant then last_instant := now;
  !last_instant

(* Measured against [instant], which is what a deadline was computed from. A
   signal cuts a sleep short, so it is taken again until the deadline passes. *)
let rec wait_until deadline =
  let left = deadline - instant () in
  if left > 0
  then (
    (try Unix.sleepf (Float.of_int left /. 1e9) with Unix.Unix_error (Unix.EINTR, _, _) -> ());
    wait_until deadline)

(* ---- entropy ---- *)

let urandom = lazy (try Some (open_in_bin "/dev/urandom") with Sys_error _ -> None)
let fallback = lazy (Random.State.make_self_init ())

let random_bits () =
  match Lazy.force urandom with
  | Some channel -> Int64.to_int (String.get_int64_le (really_input_string channel 8) 0) land max_int
  | None -> Int64.to_int (Random.State.bits64 (Lazy.force fallback)) land max_int

(* ---- subprocesses ---- *)

type child =
  { pid : int
  ; mutable input : Unix.file_descr option
  ; output : Unix.file_descr option
  ; errors : Unix.file_descr option
  ; mutable code : int option
  }

let children : (int, child) Hashtbl.t = Hashtbl.create 8
let next_child = ref 0

(* A child that exits before reading what was written to it would otherwise
   end this process with SIGPIPE rather than failing the write. *)
let ignore_sigpipe = lazy (if not Sys.win32 then Sys.set_signal Sys.sigpipe Sys.Signal_ignore)

let rec retrying f = try f () with Unix.Unix_error (Unix.EINTR, _, _) -> retrying f

let close_quietly fd = try Unix.close fd with Unix.Unix_error _ -> ()

let code_of = function
  | Unix.WEXITED n -> n
  | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + abs n

let spawn ~program ~args ~overrides ~dir ~modes =
  Lazy.force ignore_sigpipe;
  (* Inherited, the child writes to the same descriptor this process is still
     holding output for. *)
  flush stdout;
  flush stderr;
  let opened = ref [] in
  let endpoint mode ~inherited ~child_reads =
    match mode with
    | 1 ->
      let r, w = Unix.pipe ~cloexec:true () in
      if child_reads
      then (
        opened := r :: !opened;
        r, Some w)
      else (
        opened := w :: !opened;
        w, Some r)
    | 2 ->
      let fd = Unix.openfile Filename.null [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
      opened := fd :: !opened;
      fd, None
    | _ -> inherited, None
  in
  let in_mode, out_mode, err_mode = modes in
  let child_in, input = endpoint in_mode ~inherited:Unix.stdin ~child_reads:true in
  let child_out, output = endpoint out_mode ~inherited:Unix.stdout ~child_reads:false in
  let child_err, errors = endpoint err_mode ~inherited:Unix.stderr ~child_reads:false in
  let env =
    let table = Hashtbl.copy (Lazy.force environment) in
    List.iter (fun (k, v) -> Hashtbl.replace table k v) overrides;
    Hashtbl.fold (fun k v acc -> (k ^ "=" ^ v) :: acc) table [] |> Array.of_list
  in
  (* `Unix` starts a process in this one's directory and nowhere else. *)
  let start () =
    Unix.create_process_env program (Array.of_list (program :: args)) env child_in child_out child_err
  in
  let started =
    match
      match dir with
      | "" -> start ()
      | dir ->
        let here = Sys.getcwd () in
        Sys.chdir dir;
        Fun.protect ~finally:(fun () -> Sys.chdir here) start
    with
    | pid -> pid
    | exception e ->
      List.iter close_quietly (!opened @ List.filter_map Fun.id [ input; output; errors ]);
      raise e
  in
  List.iter close_quietly !opened;
  let handle = !next_child in
  incr next_child;
  Hashtbl.replace children handle { pid = started; input; output; errors; code = None };
  handle

let close_input child =
  Option.iter close_quietly child.input;
  child.input <- None

let wait child =
  close_input child;
  match child.code with
  | Some code -> code
  | None ->
    let _, status = retrying (fun () -> Unix.waitpid [] child.pid) in
    let code = code_of status in
    child.code <- Some code;
    code

(* Both streams to their end at once: read one after the other, a child that
   fills the second pipe while the first is still open waits on this process
   forever. Windows cannot `select` on a pipe, so there they are read in turn. *)
let drain child =
  let chunk = Bytes.create 65536 in
  let out = Buffer.create 256
  and err = Buffer.create 256 in
  let read_into fd buffer =
    let n = retrying (fun () -> Unix.read fd chunk 0 (Bytes.length chunk)) in
    Buffer.add_subbytes buffer chunk 0 n;
    n > 0
  in
  let streams = List.filter_map (fun (fd, b) -> Option.map (fun fd -> fd, b) fd) [ child.output, out; child.errors, err ] in
  if Sys.win32
  then List.iter (fun (fd, b) -> while read_into fd b do () done) streams
  else (
    let rec loop open_ =
      if open_ <> []
      then (
        let ready, _, _ = retrying (fun () -> Unix.select (List.map fst open_) [] [] (-1.0)) in
        loop (List.filter (fun (fd, b) -> (not (List.mem fd ready)) || read_into fd b) open_))
    in
    loop streams);
  List.iter (fun (fd, _) -> close_quietly fd) streams;
  Buffer.contents out, Buffer.contents err

let child_of span handle =
  match Hashtbl.find_opt children handle with
  | Some child -> child
  | None -> Value.fail span "No process has the handle %d." handle

let functions : (string * string * (unit -> Types.infer_ty list * Types.infer_ty)) list =
  let open Types in
  let status_text = ITuple [ IInt; IStr ] in
  [ "__args", "", (fun () -> [], iarray IStr)
  ; "__env_get", "", (fun () -> [ IStr ], ITuple [ IBool; IStr ])
  ; "__env_set", "", (fun () -> [ IStr; IStr ], IUnit)
  ; "__env_remove", "", (fun () -> [ IStr ], IUnit)
  ; "__env_all", "", (fun () -> [], iarray (ITuple [ IStr; IStr ]))
  ; "__time_wall", "", (fun () -> [], IInt)
  ; "__time_instant", "", (fun () -> [], IInt)
  ; "__time_wait_until", "", (fun () -> [ IInt ], IUnit)
  ; "__exit", "", (fun () -> [ IInt ], IUnit)
  ; "__random_bits", "", (fun () -> [], IInt)
  ; "__fs_list", "", (fun () -> [ IStr ], ITuple [ IInt; iarray IStr; IStr ])
  ; "__fs_metadata", "", (fun () -> [ IStr ], ITuple [ IInt; IInt; IInt; IStr ])
  ; "__fs_make_dir", "", (fun () -> [ IStr ], status_text)
  ; "__fs_remove", "", (fun () -> [ IStr ], status_text)
  ; "__fs_rename", "", (fun () -> [ IStr; IStr ], status_text)
  ; ( "__process_spawn"
    , ""
    , fun () ->
        ( [ IStr; iarray IStr; iarray (ITuple [ IStr; IStr ]); IStr; IInt; IInt; IInt ]
        , ITuple [ IInt; IInt; IStr ] ) )
  ; "__process_read", "", (fun () -> [ IInt; IInt; IInt ], ITuple [ IInt; iarray IByte; IStr ])
  ; "__process_write", "", (fun () -> [ IInt; iarray IByte ], status_text)
  ; "__process_close_input", "", (fun () -> [ IInt ], status_text)
  ; "__process_wait", "", (fun () -> [ IInt ], ITuple [ IInt; IInt; IStr ])
  ; ( "__process_drain"
    , ""
    , fun () -> [ IInt ], ITuple [ IInt; IInt; iarray IByte; iarray IByte; IStr ] )
  ]

let values ~native =
  [ native "__args" 0 (fun _ _ ->
      Value.Array (Array.of_list (List.map str !arguments)))
  ; native "__env_get" 1 (fun span args ->
      match args with
      | [ Value.Str name ] ->
        (match Hashtbl.find_opt (Lazy.force environment) (Utf8.encode name) with
         | Some v -> Value.Tuple [ Value.Bool true; str v ]
         | None -> Value.Tuple [ Value.Bool false; no_message ])
      | _ -> Value.fail span "__env_get takes a name.")
  ; native "__env_set" 2 (fun span args ->
      match args with
      | [ Value.Str name; Value.Str v ] ->
        Hashtbl.replace (Lazy.force environment) (Utf8.encode name) (Utf8.encode v);
        Value.Unit
      | _ -> Value.fail span "__env_set takes a name and a value.")
  ; native "__env_remove" 1 (fun span args ->
      match args with
      | [ Value.Str name ] ->
        Hashtbl.remove (Lazy.force environment) (Utf8.encode name);
        Value.Unit
      | _ -> Value.fail span "__env_remove takes a name.")
  ; native "__env_all" 0 (fun _ _ ->
      Value.Array
        (Array.of_list (List.map (fun (k, v) -> Value.Tuple [ str k; str v ]) (variables ()))))
  ; native "__time_wall" 0 (fun _ _ -> Value.Int (nanos (Unix.gettimeofday ())))
  ; native "__time_instant" 0 (fun _ _ -> Value.Int (instant ()))
  ; native "__exit" 1 (fun span args ->
      match args with
      | [ Value.Int code ] -> raise (Value.Exited code)
      | _ -> Value.fail span "__exit takes an exit code.")
  ; native "__time_wait_until" 1 (fun span args ->
      match args with
      | [ Value.Int deadline ] ->
        wait_until deadline;
        Value.Unit
      | _ -> Value.fail span "__time_wait_until takes an instant.")
  ; native "__random_bits" 0 (fun _ _ -> Value.Int (random_bits ()))
  ; native "__fs_list" 1 (fun span args ->
      match args with
      | [ Value.Str path ] ->
        (match Sys.readdir (Utf8.encode path) with
         | names ->
           Array.sort String.compare names;
           Value.Tuple [ Value.Int 0; Value.Array (Array.map str names); no_message ]
         | exception Sys_error message ->
           let status =
             match Unix.stat (Utf8.encode path) with
             | _ -> 3
             | exception Unix.Unix_error (e, _, _) -> status_of_unix e
           in
           Value.Tuple [ Value.Int status; Value.Array [||]; str message ])
      | _ -> Value.fail span "__fs_list takes a path.")
  ; native "__fs_metadata" 1 (fun span args ->
      match args with
      | [ Value.Str path ] ->
        (match Unix.stat (Utf8.encode path) with
         | stat ->
           let kind =
             match stat.Unix.st_kind with
             | Unix.S_REG -> 0
             | Unix.S_DIR -> 1
             | _ -> 2
           in
           Value.Tuple [ Value.Int 0; Value.Int kind; Value.Int stat.Unix.st_size; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_unix e in
           Value.Tuple [ status; Value.Int 0; Value.Int 0; message ])
      | _ -> Value.fail span "__fs_metadata takes a path.")
  ; native "__fs_make_dir" 1 (fun span args ->
      match args with
      | [ Value.Str path ] ->
        (match Unix.mkdir (Utf8.encode path) 0o755 with
         | () -> Value.Tuple [ Value.Int 0; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_unix e in
           Value.Tuple [ status; message ])
      | _ -> Value.fail span "__fs_make_dir takes a path.")
  ; native "__fs_remove" 1 (fun span args ->
      match args with
      | [ Value.Str path ] ->
        let path = Utf8.encode path in
        (match
           match (Unix.lstat path).Unix.st_kind with
           | Unix.S_DIR -> Unix.rmdir path
           | _ -> Unix.unlink path
         with
         | () -> Value.Tuple [ Value.Int 0; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_unix e in
           Value.Tuple [ status; message ])
      | _ -> Value.fail span "__fs_remove takes a path.")
  ; native "__fs_rename" 2 (fun span args ->
      match args with
      | [ Value.Str from; Value.Str to_ ] ->
        (match Unix.rename (Utf8.encode from) (Utf8.encode to_) with
         | () -> Value.Tuple [ Value.Int 0; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_unix e in
           Value.Tuple [ status; message ])
      | _ -> Value.fail span "__fs_rename takes two paths.")
  ; native "__process_spawn" 7 (fun span args ->
      match args with
      | [ program; argv; env; dir; Value.Int i; Value.Int o; Value.Int e ] ->
        (match text_of program, texts_of argv, pairs_of env, text_of dir with
         | Some program, Some args, Some overrides, Some dir ->
           (match spawn ~program ~args ~overrides ~dir ~modes:(i, o, e) with
            | handle -> Value.Tuple [ Value.Int 0; Value.Int handle; no_message ]
            | exception Unix.Unix_error (e, _, _) ->
              Value.Tuple
                [ Value.Int (status_of_unix e); Value.Int (-1); str (program ^ ": " ^ Unix.error_message e) ]
            | exception Sys_error message ->
              Value.Tuple [ Value.Int 3; Value.Int (-1); str message ])
         | _ -> Value.fail span "__process_spawn was given the wrong arguments.")
      | _ -> Value.fail span "__process_spawn was given the wrong arguments.")
  ; native "__process_read" 3 (fun span args ->
      match args with
      | [ Value.Int handle; Value.Int which; Value.Int max ] ->
        let child = child_of span handle in
        (match if which = 1 then child.output else child.errors with
         | None ->
           Value.Tuple [ Value.Int 3; byte_array ""; str "The stream was not piped." ]
         | Some fd ->
           let buffer = Bytes.create (Int.max 1 max) in
           (match retrying (fun () -> Unix.read fd buffer 0 (Bytes.length buffer)) with
            | n -> Value.Tuple [ Value.Int 0; byte_array (Bytes.sub_string buffer 0 n); no_message ]
            | exception Unix.Unix_error (e, _, _) ->
              let status, message = failed_unix e in
              Value.Tuple [ status; byte_array ""; message ]))
      | _ -> Value.fail span "__process_read takes a handle, a stream and a count.")
  ; native "__process_write" 2 (fun span args ->
      match args with
      | [ Value.Int handle; data ] ->
        let child = child_of span handle in
        (match child.input, bytes_of data with
         | Some fd, Some data ->
           let rec all from =
             if from < String.length data
             then all (from + retrying (fun () -> Unix.write_substring fd data from (String.length data - from)))
           in
           (match all 0 with
            | () -> Value.Tuple [ Value.Int 0; no_message ]
            | exception Unix.Unix_error (e, _, _) ->
              let status, message = failed_unix e in
              Value.Tuple [ status; message ])
         | None, _ -> Value.Tuple [ Value.Int 3; str "The process's input is closed, or was not piped." ]
         | _, None -> Value.fail span "__process_write takes bytes.")
      | _ -> Value.fail span "__process_write takes a handle and bytes.")
  ; native "__process_close_input" 1 (fun span args ->
      match args with
      | [ Value.Int handle ] ->
        close_input (child_of span handle);
        Value.Tuple [ Value.Int 0; no_message ]
      | _ -> Value.fail span "__process_close_input takes a handle.")
  ; native "__process_wait" 1 (fun span args ->
      match args with
      | [ Value.Int handle ] ->
        (match wait (child_of span handle) with
         | code -> Value.Tuple [ Value.Int 0; Value.Int code; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_unix e in
           Value.Tuple [ status; Value.Int (-1); message ])
      | _ -> Value.fail span "__process_wait takes a handle.")
  ; native "__process_drain" 1 (fun span args ->
      match args with
      | [ Value.Int handle ] ->
        let child = child_of span handle in
        close_input child;
        (match
           let out, err = drain child in
           out, err, wait child
         with
         | out, err, code -> Value.Tuple [ Value.Int 0; Value.Int code; byte_array out; byte_array err; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_unix e in
           Value.Tuple [ status; Value.Int (-1); byte_array ""; byte_array ""; message ])
      | _ -> Value.fail span "__process_drain takes a handle.")
  ]
