(* A compiled package: its declarations, mangled but not yet metaprocessed, and
   the names each of its units exports.

   There is no schema. The lockfile pins an exact compiler and every package in
   a build is compiled by that one binary, so an artifact is never read by a
   compiler other than the one that wrote it -- which is what lets this be
   `Marshal` of the compiler's own types, tagged with the version that wrote
   it. A compiler whose types have changed rejects what it finds and the
   package is built again. *)

type unit_interface =
  { namespace : string
  ; exports : string list
  }

(* Every file this artifact was built from, and what it held. A `meta` block
   reaches files nobody declared, so the list is recorded during the build
   rather than guessed from the manifest. *)
type input =
  { path : string
  ; digest : string
  }

type t =
  { compiler : string
  ; package : string
  ; units : unit_interface list
  ; program : Ast.program
  ; inputs : input list
  ; fingerprint : string
  }

let digest_of path = try Some (Digest.to_hex (Digest.file path)) with _ -> None

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
    (fun () -> Marshal.to_channel out artifact [])

type failure =
  | Missing
  | Stale of string (* the compiler that wrote it *)
  | Unreadable

let load path : (t, failure) result =
  if not (Sys.file_exists path)
  then Error Missing
  else (
    match
      let inp = In_channel.open_bin path in
      Fun.protect
        ~finally:(fun () -> In_channel.close inp)
        (fun () -> (Marshal.from_channel inp : t))
    with
    | artifact ->
      if String.equal artifact.compiler Release.version
      then Ok artifact
      else Error (Stale artifact.compiler)
    | exception _ -> Error Unreadable)

let interface (artifact : t) namespace =
  List.find_opt (fun u -> String.equal u.namespace namespace) artifact.units
