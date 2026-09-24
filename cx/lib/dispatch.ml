(* There is no shim. Every toolchain ships a complete `cx`, and the one on
   $PATH is a copy of whichever was installed last -- forward only. On startup
   `cx` finds the package it was invoked in, reads the toolchain that package
   requires, and hands the job to that toolchain's `cx` if it is not the one
   running. Dispatch is a mode of the whole tool rather than a program in front
   of it, so there is nothing separate that can be too old to update itself. *)

open Bootstrap

(* Two phases, because the graph can ask for more than the root does. The first
   reads the root's floor; the second, after the dependencies are known, takes
   the highest floor over all of them. The second exec cannot cascade: the
   toolchain it hands to sees the same graph and the same maximum. *)
let floor_of root =
  Preamble.of_file (Filename.concat root Manifest.file_name)

(* Every manifest the graph reaches, read with the frozen reader rather than the
   real one: a dependency's manifest may also be written for a newer compiler. *)
let graph_floor root =
  let seen = Hashtbl.create 8 in
  let best = ref None in
  let raise_to text =
    match Version.of_string text with
    | Error _ -> ()
    | Ok version ->
      (match !best with
       | Some (_, current) when Version.compare current version >= 0 -> ()
       | _ -> best := Some (text, version))
  in
  let rec walk root =
    let root = Filename.concat root "" in
    if not (Hashtbl.mem seen root)
    then (
      Hashtbl.replace seen root ();
      Option.iter raise_to (floor_of root);
      (* Only the paths, and only as written: resolving them properly is the
         resolver's job and the resolver may be in another toolchain. *)
      match Manifest.load (Filename.concat root Manifest.file_name) with
      | Error _ -> ()
      | Ok manifest ->
        List.iter
          (fun (d : Manifest.dependency) ->
            match d.Manifest.source with
            | Manifest.Path (path, _) -> walk (Filename.concat root path)
            (* Its floor is in the index, which the resolver reads and this
               deliberately does not: dispatch is the frozen part. *)
            | Manifest.Registry _ -> ())
          manifest.Manifest.dependencies)
  in
  walk root;
  Option.map fst !best

(* Set across the exec, so a toolchain that is not the version it was installed
   as cannot bounce the job back and forth forever. Handing off happens once. *)
let asks_for_help args =
  List.exists (fun arg -> String.equal arg "-h" || String.equal arg "--help") args

(* The commands that read the package's code, and so need the toolchain it was
   written for. The rest -- installing that toolchain above all -- runs here
   whatever the package asks for, or a machine holding only an old `cx` has no
   way to get a newer one. Help is about the `cx` that was run, so it is never
   handed on. *)
let dispatched = function
  | ("build" | "update" | "run" | "test" | "publish") :: rest -> not (asks_for_help rest)
  | _ -> false

let marker = "CRONYX_DISPATCHED"

type decision =
  | Run_here
  | Hand_to of string * string
  | Missing of string
  | Mislabelled of string

let decide ~running ~wanted =
  match wanted with
  | None -> Run_here
  | Some wanted ->
    (match Version.of_string wanted, Version.of_string running with
     | Ok wanted_v, Ok running_v when Version.compare running_v wanted_v >= 0 -> Run_here
     | _ ->
       (match Sys.getenv_opt marker with
        | Some already when String.equal already wanted -> Mislabelled wanted
        | _ ->
          let path = Home.toolchain_cx wanted in
          if Sys.file_exists path then Hand_to (wanted, path) else Missing wanted))

let unavailable version =
  Printf.sprintf
    "This package needs Cronyx %s, and %s is running.\n\
     Fetch it from https://github.com/brendancron/CronyxLang/releases/tag/v%s, then install \
     it with `cx toolchain install %s <path-to-cx>`."
    version
    Release.version
    version
    version

let mislabelled version =
  Printf.sprintf
    "The toolchain installed as %s reports itself as %s, so it cannot be the one this package \
     needs.\n\
     Reinstall it, or install %s from https://github.com/brendancron/CronyxLang/releases/tag/v%s."
    version
    Release.version
    version
    version

(* Replaces the process. The toolchain that takes over reads the same manifests
   and reaches the same answer, so it hands the job on no further -- and the
   marker means a toolchain that lies about its version stops the job rather
   than passing it around.

   Windows has no exec: what it has spelt that way spawns and lets the caller
   die, so the exit code and the order the two processes' output interleaves are
   both lost. Waiting for the child and exiting as it did is what makes the hand
   off invisible to whoever ran `cx`. *)
let hand_to version path argv =
  Unix.putenv marker version;
  if not Sys.win32
  then Unix.execv path argv
  else (
    let child = Unix.create_process path argv Unix.stdin Unix.stdout Unix.stderr in
    match Unix.waitpid [] child with
    | _, Unix.WEXITED code -> exit code
    | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> exit 1)
