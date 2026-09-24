(* Where toolchains live. `CRONYX_HOME` so that a test, or a machine with more
   than one of these, does not have to touch the user's own. *)

(* Windows sets `USERPROFILE` and not `HOME`, so a lookup that knows only the
   latter falls through to a relative path and installs toolchains into whichever
   package the user happened to be standing in. *)
let home () =
  match Sys.getenv_opt "HOME" with
  | Some _ as home -> home
  | None -> Sys.getenv_opt "USERPROFILE"

let root () =
  match Sys.getenv_opt "CRONYX_HOME" with
  | Some dir -> dir
  | None ->
    (match home () with
     | Some home -> Filename.concat home ".cronyx"
     | None -> ".cronyx")

let toolchains () = Filename.concat (root ()) "toolchains"
let bin () = Filename.concat (root ()) "bin"
let executable = if Sys.win32 then "cx.exe" else "cx"
let cx () = Filename.concat (bin ()) executable
let toolchain version = Filename.concat (toolchains ()) version

let toolchain_cx version =
  Filename.concat (toolchain version) (Filename.concat "bin" executable)

let rec ensure dir =
  if not (Sys.file_exists dir)
  then (
    ensure (Filename.dirname dir);
    Sys.mkdir dir 0o755)

let installed () =
  let dir = toolchains () in
  if not (Sys.file_exists dir)
  then []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name -> Sys.file_exists (toolchain_cx name))
    |> List.filter_map (fun name ->
      match Version.of_string name with
      | Ok version -> Some (name, version)
      | Error _ -> None)
    |> List.sort (fun (_, a) (_, b) -> Version.compare a b)

let highest () =
  match List.rev (installed ()) with
  | (name, version) :: _ -> Some (name, version)
  | [] -> None
