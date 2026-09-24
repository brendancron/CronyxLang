(* What a package is once it leaves its directory. A real registry serves a
   tarball; this serves the same bytes in a shape both ends here already agree
   on, so the checksum, the cache and the verification are the real ones and
   only the transport is a stand-in.

   Deterministic by construction: entries sorted by path, no timestamps, no
   modes. Two packings of one tree are the same bytes, which is what makes the
   checksum in a lockfile mean anything. *)

let magic = "cxar1\n"

let pack files =
  let buffer = Buffer.create 4096 in
  Buffer.add_string buffer magic;
  List.sort (fun (a, _) (b, _) -> String.compare a b) files
  |> List.iter (fun (path, contents) ->
    Buffer.add_string buffer (Printf.sprintf "%s\n%d\n" path (String.length contents));
    Buffer.add_string buffer contents);
  Buffer.contents buffer

type error = string

let unpack text : ((string * string) list, error) result =
  let n = String.length text in
  if n < String.length magic || not (String.equal (String.sub text 0 (String.length magic)) magic)
  then Error "not a Cronyx archive"
  else (
    let rec entries at acc =
      if at >= n
      then Ok (List.rev acc)
      else (
        match String.index_from_opt text at '\n' with
        | None -> Error "truncated archive"
        | Some path_end ->
          let path = String.sub text at (path_end - at) in
          (match String.index_from_opt text (path_end + 1) '\n' with
           | None -> Error "truncated archive"
           | Some size_end ->
             let size = String.sub text (path_end + 1) (size_end - path_end - 1) in
             (match int_of_string_opt size with
              | None -> Error (Printf.sprintf "'%s' is not a length" size)
              | Some size when size_end + 1 + size > n -> Error "truncated archive"
              | Some size ->
                entries (size_end + 1 + size) ((path, String.sub text (size_end + 1) size) :: acc))))
    in
    entries (String.length magic) [])

let checksum text = "blake2b:" ^ Digest.BLAKE256.to_hex (Digest.BLAKE256.string text)

(* What a package ships: every file under [root] by its path relative to it,
   less what belongs to this checkout rather than to the package. `target/` is
   output. Anything hidden is a VCS directory, an ignore file or an editor's,
   none of which a consumer wants. `cronyx.lock` pins this package's own build,
   and a consumer resolves its own. `tests/` at the root is compiled against the
   package rather than into it, and a consumer has neither the test-only
   dependencies to build it nor a reason to. *)
let of_directory root =
  let shipped ~top entry ~directory =
    not
      (String.starts_with ~prefix:"." entry
       || (directory && String.equal entry "target")
       || (top && directory && String.equal entry "tests")
       || (top && (not directory) && String.equal entry "cronyx.lock"))
  in
  let rec walk prefix dir =
    Sys.readdir dir
    |> Array.to_list
    |> List.sort String.compare
    |> List.concat_map (fun entry ->
      let path = Filename.concat dir entry in
      (* Not [Filename.concat]: an archive is read on a machine other than the
         one that packed it, so its entries are spelled the one way rather than
         the way the packing machine happens to spell a separator. *)
      let relative = if String.equal prefix "" then entry else prefix ^ "/" ^ entry in
      let directory = Sys.is_directory path in
      if not (shipped ~top:(String.equal prefix "") entry ~directory)
      then []
      else if directory
      then walk relative path
      else [ relative, In_channel.with_open_bin path In_channel.input_all ])
  in
  walk "" root

let into_directory root files =
  List.iter
    (fun (path, contents) ->
      let full = Filename.concat root path in
      Home.ensure (Filename.dirname full);
      Out_channel.with_open_bin full (fun out -> Out_channel.output_string out contents))
    files
