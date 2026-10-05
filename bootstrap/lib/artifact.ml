(* A compiled package: its declarations, mangled but not yet metaprocessed, and
   the names each of its units exports.

   There is no schema. The lockfile pins an exact compiler and every package in
   a build is compiled by that one binary, so an artifact is never read by a
   compiler other than the one that wrote it -- which is what lets this be
   `Marshal` of the compiler's own types, behind a header naming the build that
   wrote it. A compiler whose header differs rejects what it finds and the
   package is built again. *)

type unit_interface =
  { namespace : string
  (* Where the unit was written, relative to the root of the package that owns
     it -- `collections/HashMap.cx`. [None] for a unit this artifact embeds
     rather than owns: a dependency's path is its own package's business, and an
     embedded unit's declarations carry that package's names rather than these. *)
  ; path : string option
  (* The unit's own prose: the doc comment at the top of its file, which belongs
     to no declaration in it. *)
  ; doc : string option
  ; exports : string list
  (* An effect's operations, which are members and so are absent from
     [exports]: a consumer writing `sig.boop` needs to know that `boop` keeps
     the name it was written with rather than taking the unit's. *)
  ; operations : string list
  }

(* Every file this artifact was built from, and what it held. A `meta` block
   reaches files nobody declared, so the list is recorded during the build
   rather than guessed from the manifest. *)
type input =
  { path : string
  ; digest : string
  }

type t =
  { package : string
  ; units : unit_interface list
  ; program : Ast.program
  ; inputs : input list
  ; fingerprint : string
  }

let digest_of path = try Some (Digest.to_hex (Digest.file path)) with _ -> None

(* The standard library is found when the toolchain runs rather than built into
   it, so a library edited under an unchanged binary has to change the name too,
   or artifacts compiled against the old one stay fresh. *)
let stdlib_digest () =
  match Toolchain.stdlib () with
  | None -> "no-stdlib"
  | Some dir ->
    let rec files under =
      Sys.readdir (Filename.concat dir under)
      |> Array.to_list
      |> List.sort String.compare
      |> List.concat_map (fun entry ->
        let path = if String.equal under "" then entry else Filename.concat under entry in
        if Sys.is_directory (Filename.concat dir path)
        then files path
        else if Filename.check_suffix entry ".cx"
        then [ path ^ " " ^ Option.value (digest_of (Filename.concat dir path)) ~default:"" ]
        else [])
    in
    Digest.to_hex (Digest.string (String.concat "\n" (files "")))

(* The version alone does not name a compiler: a build of the tree between two
   releases reports the last one while its types have moved on. The binary's own
   digest does. One that cannot be read names nothing it could match, so its
   artifacts are always rebuilt rather than trusted. *)
let compiler =
  lazy
    (Release.version
     ^ "+"
     ^ (match digest_of Sys.executable_name with
        | Some digest -> digest
        | None -> "unread-" ^ string_of_float (Unix.gettimeofday ()))
     ^ "+"
     ^ stdlib_digest ())

(* One string over everything the build depended on. The compiler version is in
   it because an artifact is only readable by the compiler that wrote it, and
   the dependencies' own fingerprints are in it so that a change deep in the
   graph reaches everything above it. *)
let fingerprint_of ~compiler ~profile ~inputs ~dependencies =
  Digest.to_hex
    (Digest.string
       (String.concat
          "\n"
          ((compiler :: profile :: List.sort String.compare dependencies)
           @ List.map (fun i -> i.path ^ " " ^ i.digest) inputs)))

let inputs_of paths =
  List.sort String.compare paths
  |> List.map (fun path ->
    { path; digest = (match digest_of path with Some d -> d | None -> "missing") })

let extension = ".cxa"

let save path (artifact : t) =
  let out = Out_channel.open_bin path in
  Fun.protect
    ~finally:(fun () -> Out_channel.close out)
    (fun () ->
      Out_channel.output_string out (Lazy.force compiler ^ "\n");
      Marshal.to_channel out artifact [])

type failure =
  | Missing
  | Stale of string (* the compiler that wrote it *)
  | Unreadable

let load path : (t, failure) result =
  if not (Sys.file_exists path)
  then Error Missing
  else (
    try
      let inp = In_channel.open_bin path in
      Fun.protect
        ~finally:(fun () -> In_channel.close inp)
        (fun () ->
          match In_channel.input_line inp with
          | None -> Error Unreadable
          | Some writer when not (String.equal writer (Lazy.force compiler)) -> Error (Stale writer)
          (* Only now: [Marshal] does not fail on a value of another shape, it
             returns one, and the crash comes from whatever reads it next. *)
          | Some _ -> Ok (Marshal.from_channel inp : t))
    with
    | _ -> Error Unreadable)

let interface (artifact : t) namespace =
  List.find_opt (fun u -> String.equal u.namespace namespace) artifact.units
