(* What the root hands a program of the OS: its arguments and environment, the
   clocks, entropy, directories, subprocesses and sockets. Each answer is a
   tuple whose first part is a status the library turns into an `IoError`: 0 is
   success, then NotFound, Denied and Other; a socket adds the rest of
   [net_status]. *)

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
   forever. The second is read on a thread rather than through `select`, which
   Windows cannot do on a pipe -- and one way on every platform is the way the
   tests on any of them check. *)
let drain child =
  let read_all fd buffer =
    let chunk = Bytes.create 65536 in
    let rec go () =
      let n = retrying (fun () -> Unix.read fd chunk 0 (Bytes.length chunk)) in
      if n > 0
      then (
        Buffer.add_subbytes buffer chunk 0 n;
        go ())
    in
    go ()
  in
  let out = Buffer.create 256
  and err = Buffer.create 256 in
  (match child.output, child.errors with
   | Some o, Some e ->
     let reader = Thread.create (fun () -> read_all e err) () in
     read_all o out;
     Thread.join reader
   | Some o, None -> read_all o out
   | None, Some e -> read_all e err
   | None, None -> ());
  Option.iter close_quietly child.output;
  Option.iter close_quietly child.errors;
  Buffer.contents out, Buffer.contents err

let child_of span handle =
  match Hashtbl.find_opt children handle with
  | Some child -> child
  | None -> Value.fail span "No process has the handle %d." handle

(* ---- sockets ---- *)

(* Every socket is non-blocking, so an operation that would wait answers
   [would_block] instead, and the task waits for the scheduler to see the
   socket ready. A handle is a number rather than the descriptor, which is not
   one on Windows. *)
let sockets : (int, Unix.file_descr) Hashtbl.t = Hashtbl.create 8
let next_socket = ref 0
let would_block = 4

(* Windows hands some failures back as Winsock's own numbers rather than the
   errors they mean -- a refused connection read through [getsockopt_error]
   is [EUNKNOWNERR 10061] -- so those are read here as well. *)
let net_status (e : Unix.error) =
  match e with
  | Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINPROGRESS | Unix.EUNKNOWNERR (10035 | 10036) -> would_block
  | Unix.ECONNREFUSED | Unix.EUNKNOWNERR 10061 -> 5
  | Unix.ECONNRESET | Unix.EPIPE | Unix.ECONNABORTED | Unix.EUNKNOWNERR (10053 | 10054) -> 6
  | Unix.EADDRINUSE | Unix.EUNKNOWNERR 10048 -> 7
  | Unix.ETIMEDOUT | Unix.EUNKNOWNERR 10060 -> 8
  | e -> status_of_unix e

let failed_net e = Value.Int (net_status e), str (Unix.error_message e)

let socket_of span handle =
  match Hashtbl.find_opt sockets handle with
  | Some fd -> fd
  | None -> Value.fail span "No socket has the handle %d." handle

let held fd =
  Unix.set_nonblock fd;
  let handle = !next_socket in
  incr next_socket;
  Hashtbl.replace sockets handle fd;
  handle

let addresses host =
  Unix.getaddrinfo host "" [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  |> List.filter_map (fun (info : Unix.addr_info) ->
    match info.Unix.ai_addr with
    | Unix.ADDR_INET (a, _) -> Some (Unix.string_of_inet_addr a)
    | Unix.ADDR_UNIX _ -> None)
  |> List.fold_left (fun seen a -> if List.mem a seen then seen else seen @ [ a ]) []

let endpoint address port =
  let a = Unix.inet_addr_of_string address in
  Unix.domain_of_sockaddr (Unix.ADDR_INET (a, port)), Unix.ADDR_INET (a, port)

let shown_address = function
  | Unix.ADDR_INET (a, port) -> Printf.sprintf "%s:%d" (Unix.string_of_inet_addr a) port
  | Unix.ADDR_UNIX path -> path

let listen address port =
  let domain, at = endpoint address port in
  let fd = Unix.socket ~cloexec:true domain Unix.SOCK_STREAM 0 in
  match
    Unix.setsockopt fd Unix.SO_REUSEADDR true;
    Unix.bind fd at;
    Unix.listen fd 128
  with
  | () -> held fd
  | exception e ->
    close_quietly fd;
    raise e

(* The connection goes on once this returns; a socket answered [would_block]
   is connected, or refused, once it is writable, and [connected] says which. *)
let connect address port =
  let domain, at = endpoint address port in
  let fd = Unix.socket ~cloexec:true domain Unix.SOCK_STREAM 0 in
  Unix.set_nonblock fd;
  match Unix.connect fd at with
  | () -> held fd, 0
  | exception Unix.Unix_error ((Unix.EINPROGRESS | Unix.EWOULDBLOCK | Unix.EAGAIN), _, _) -> held fd, would_block
  | exception e ->
    close_quietly fd;
    raise e

let bind address port =
  let domain, at = endpoint address port in
  let fd = Unix.socket ~cloexec:true domain Unix.SOCK_DGRAM 0 in
  match Unix.bind fd at with
  | () -> held fd
  | exception e ->
    close_quietly fd;
    raise e

(* The host is looked up in the socket's own family: a socket bound to an IPv4
   address cannot send to an IPv6 one. *)
let destination fd host port =
  let family = Unix.domain_of_sockaddr (Unix.getsockname fd) in
  match
    Unix.getaddrinfo host (string_of_int port) [ Unix.AI_SOCKTYPE Unix.SOCK_DGRAM; Unix.AI_FAMILY family ]
  with
  | info :: _ -> Some info.Unix.ai_addr
  | [] -> None

(* Windows reports a connection that failed as exceptional rather than
   writable, so a socket waited on for writing is watched for both, and either
   wakes it: [connected] then says which it was. *)
let net_wait reads writes timeout =
  let fds handles = List.filter_map (Hashtbl.find_opt sockets) handles in
  let ready handles fds = List.filter (fun h -> List.mem (Hashtbl.find sockets h) fds) handles in
  let limit = if timeout < 0 then -1.0 else Float.of_int timeout /. 1e9 in
  match Unix.select (fds reads) (fds writes) (fds writes) limit with
  | r, w, e -> ready reads r, ready writes (w @ e)
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> [], []

let handles_of (v : Value.value) =
  match v with
  | Value.Array items ->
    Array.to_list items |> List.filter_map (function Value.Int h -> Some h | _ -> None)
  | _ -> []

let int_array handles = Value.Array (Array.of_list (List.map (fun h -> Value.Int h) handles))

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
  ; "__net_lookup", "", (fun () -> [ IStr ], ITuple [ IInt; iarray IStr; IStr ])
  ; "__net_listen", "", (fun () -> [ IStr; IInt ], ITuple [ IInt; IInt; IStr ])
  ; "__net_connect", "", (fun () -> [ IStr; IInt ], ITuple [ IInt; IInt; IStr ])
  ; "__net_connected", "", (fun () -> [ IInt ], status_text)
  ; "__net_accept", "", (fun () -> [ IInt ], ITuple [ IInt; IInt; IStr ])
  ; "__net_read", "", (fun () -> [ IInt; IInt ], ITuple [ IInt; iarray IByte; IStr ])
  ; "__net_write", "", (fun () -> [ IInt; iarray IByte ], ITuple [ IInt; IInt; IStr ])
  ; "__net_shutdown_write", "", (fun () -> [ IInt ], status_text)
  ; "__net_close", "", (fun () -> [ IInt ], status_text)
  ; "__net_local_port", "", (fun () -> [ IInt ], IInt)
  ; "__net_peer", "", (fun () -> [ IInt ], IStr)
  ; "__net_wait", "", (fun () -> [ iarray IInt; iarray IInt; IInt ], ITuple [ iarray IInt; iarray IInt ])
  ; "__udp_bind", "", (fun () -> [ IStr; IInt ], ITuple [ IInt; IInt; IStr ])
  ; "__udp_send", "", (fun () -> [ IInt; IStr; IInt; iarray IByte ], status_text)
  ; ( "__udp_receive"
    , ""
    , fun () -> [ IInt ], ITuple [ IInt; iarray IByte; IStr; IInt; IStr ] )
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
  ; native "__net_lookup" 1 (fun span args ->
      match args with
      | [ Value.Str host ] ->
        let host = Utf8.encode host in
        (match addresses host with
         | [] -> Value.Tuple [ Value.Int 1; Value.Array [||]; str ("no address for " ^ host) ]
         | found -> Value.Tuple [ Value.Int 0; Value.Array (Array.of_list (List.map str found)); no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_net e in
           Value.Tuple [ status; Value.Array [||]; message ])
      | _ -> Value.fail span "__net_lookup takes a host.")
  ; native "__net_listen" 2 (fun span args ->
      match args with
      | [ Value.Str address; Value.Int port ] ->
        (match listen (Utf8.encode address) port with
         | handle -> Value.Tuple [ Value.Int 0; Value.Int handle; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_net e in
           Value.Tuple [ status; Value.Int (-1); message ]
         | exception Failure message -> Value.Tuple [ Value.Int 3; Value.Int (-1); str message ])
      | _ -> Value.fail span "__net_listen takes an address and a port.")
  ; native "__net_connect" 2 (fun span args ->
      match args with
      | [ Value.Str address; Value.Int port ] ->
        Lazy.force ignore_sigpipe;
        (match connect (Utf8.encode address) port with
         | handle, status -> Value.Tuple [ Value.Int status; Value.Int handle; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_net e in
           Value.Tuple [ status; Value.Int (-1); message ]
         | exception Failure message -> Value.Tuple [ Value.Int 3; Value.Int (-1); str message ])
      | _ -> Value.fail span "__net_connect takes an address and a port.")
  ; native "__net_connected" 1 (fun span args ->
      match args with
      | [ Value.Int handle ] ->
        (match Unix.getsockopt_error (socket_of span handle) with
         | None -> Value.Tuple [ Value.Int 0; no_message ]
         | Some e ->
           let status, message = failed_net e in
           Value.Tuple [ status; message ])
      | _ -> Value.fail span "__net_connected takes a handle.")
  ; native "__net_accept" 1 (fun span args ->
      match args with
      | [ Value.Int handle ] ->
        (match Unix.accept ~cloexec:true (socket_of span handle) with
         | fd, _ -> Value.Tuple [ Value.Int 0; Value.Int (held fd); no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_net e in
           Value.Tuple [ status; Value.Int (-1); message ])
      | _ -> Value.fail span "__net_accept takes a handle.")
  ; native "__net_read" 2 (fun span args ->
      match args with
      | [ Value.Int handle; Value.Int max ] ->
        let buffer = Bytes.create (Int.max 1 max) in
        (match Unix.read (socket_of span handle) buffer 0 (Bytes.length buffer) with
         | n -> Value.Tuple [ Value.Int 0; byte_array (Bytes.sub_string buffer 0 n); no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_net e in
           Value.Tuple [ status; byte_array ""; message ])
      | _ -> Value.fail span "__net_read takes a handle and a count.")
  ; native "__net_write" 2 (fun span args ->
      match args with
      | [ Value.Int handle; data ] ->
        Lazy.force ignore_sigpipe;
        (match bytes_of data with
         | Some data ->
           (match Unix.single_write_substring (socket_of span handle) data 0 (String.length data) with
            | n -> Value.Tuple [ Value.Int 0; Value.Int n; no_message ]
            | exception Unix.Unix_error (e, _, _) ->
              let status, message = failed_net e in
              Value.Tuple [ status; Value.Int 0; message ])
         | None -> Value.fail span "__net_write takes bytes.")
      | _ -> Value.fail span "__net_write takes a handle and bytes.")
  ; native "__net_shutdown_write" 1 (fun span args ->
      match args with
      | [ Value.Int handle ] ->
        (match Unix.shutdown (socket_of span handle) Unix.SHUTDOWN_SEND with
         | () -> Value.Tuple [ Value.Int 0; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_net e in
           Value.Tuple [ status; message ])
      | _ -> Value.fail span "__net_shutdown_write takes a handle.")
  ; native "__net_close" 1 (fun span args ->
      match args with
      | [ Value.Int handle ] ->
        let fd = socket_of span handle in
        Hashtbl.remove sockets handle;
        (match Unix.close fd with
         | () -> Value.Tuple [ Value.Int 0; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_net e in
           Value.Tuple [ status; message ])
      | _ -> Value.fail span "__net_close takes a handle.")
  ; native "__net_local_port" 1 (fun span args ->
      match args with
      | [ Value.Int handle ] ->
        (match Unix.getsockname (socket_of span handle) with
         | Unix.ADDR_INET (_, port) -> Value.Int port
         | Unix.ADDR_UNIX _ -> Value.Int 0)
      | _ -> Value.fail span "__net_local_port takes a handle.")
  ; native "__net_peer" 1 (fun span args ->
      match args with
      | [ Value.Int handle ] ->
        (match Unix.getpeername (socket_of span handle) with
         | address -> str (shown_address address)
         | exception Unix.Unix_error _ -> no_message)
      | _ -> Value.fail span "__net_peer takes a handle.")
  ; native "__net_wait" 3 (fun span args ->
      match args with
      | [ reads; writes; Value.Int timeout ] ->
        let readable, writable = net_wait (handles_of reads) (handles_of writes) timeout in
        Value.Tuple [ int_array readable; int_array writable ]
      | _ -> Value.fail span "__net_wait takes two lists of handles and a limit.")
  ; native "__udp_bind" 2 (fun span args ->
      match args with
      | [ Value.Str address; Value.Int port ] ->
        (match bind (Utf8.encode address) port with
         | handle -> Value.Tuple [ Value.Int 0; Value.Int handle; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_net e in
           Value.Tuple [ status; Value.Int (-1); message ]
         | exception Failure message -> Value.Tuple [ Value.Int 3; Value.Int (-1); str message ])
      | _ -> Value.fail span "__udp_bind takes an address and a port.")
  ; native "__udp_send" 4 (fun span args ->
      match args with
      | [ Value.Int handle; Value.Str host; Value.Int port; data ] ->
        let fd = socket_of span handle in
        let host = Utf8.encode host in
        (match bytes_of data with
         | Some data ->
           (match destination fd host port with
            | None -> Value.Tuple [ Value.Int 1; str ("no address for " ^ host) ]
            | Some at ->
              (match Unix.sendto_substring fd data 0 (String.length data) [] at with
               | _ -> Value.Tuple [ Value.Int 0; no_message ]
               | exception Unix.Unix_error (e, _, _) ->
                 let status, message = failed_net e in
                 Value.Tuple [ status; message ])
            | exception Unix.Unix_error (e, _, _) ->
              let status, message = failed_net e in
              Value.Tuple [ status; message ])
         | None -> Value.fail span "__udp_send takes bytes.")
      | _ -> Value.fail span "__udp_send takes a handle, a host, a port and bytes.")
  ; native "__udp_receive" 1 (fun span args ->
      match args with
      | [ Value.Int handle ] ->
        (* The largest payload a UDP datagram can carry, so none is cut short:
           Windows fails a receive into too small a buffer rather than
           truncating it. *)
        let buffer = Bytes.create 65507 in
        (match Unix.recvfrom (socket_of span handle) buffer 0 (Bytes.length buffer) [] with
         | n, Unix.ADDR_INET (a, port) ->
           Value.Tuple
             [ Value.Int 0
             ; byte_array (Bytes.sub_string buffer 0 n)
             ; str (Unix.string_of_inet_addr a)
             ; Value.Int port
             ; no_message
             ]
         | n, Unix.ADDR_UNIX path ->
           Value.Tuple [ Value.Int 0; byte_array (Bytes.sub_string buffer 0 n); str path; Value.Int 0; no_message ]
         | exception Unix.Unix_error (e, _, _) ->
           let status, message = failed_net e in
           Value.Tuple [ status; byte_array ""; no_message; Value.Int 0; message ])
      | _ -> Value.fail span "__udp_receive takes a handle.")
  ]
