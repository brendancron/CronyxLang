(* Parsed and checked with the program: the declarations every program has
   before it imports anything.

   These are files -- `stdlib/core/` -- rather than a string in the compiler,
   because they are ordinary Cronyx and a reader, a doc comment and `cx docs`
   should all reach them the way they reach any other module. What they are not
   is imported: the compiler names about twenty of them itself -- `Option` and
   `Ordering` for what `partial_cmp` answers, `Range` for what `a[1:]` becomes,
   the operator traits, the reflection types -- and the syntax names the rest,
   since `[1, 2]` builds a `List` and `xs[0]` is an `Index`. A name the language
   itself produces cannot wait for an import. *)

let directory () =
  match Toolchain.stdlib () with
  | None -> None
  | Some dir ->
    let core = Filename.concat dir "core" in
    if Sys.file_exists core then Some core else None

(* Not the path on disk: a span is rendered relative to the entry, so an
   absolute one would put this machine's directory layout in a diagnostic. The
   file is named, because the reader does have it. *)
let shown name = "<core>/" ^ name

(* Whether a declaration came from here. A program may declare a type or a trait
   these also declare and get its own, which is the one thing that has to be
   told apart -- and the only thing this is asked. *)
let owns path = String.starts_with ~prefix:"<core>/" (Ast.slashed path)

(* Raised rather than failed with: a toolchain whose library is missing or half
   installed is a diagnostic like any other load error, and `Fatal error:
   exception Failure` is not one. *)
exception Missing of string

let files () =
  match directory () with
  | None ->
    raise
      (Missing
         "Cannot find the standard library's `core`, which every program is \
          compiled with. Set CRONYX_STDLIB to the library this toolchain ships.")
  | Some core ->
    Sys.readdir core
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".cx")
    (* Sorted, so the program does not depend on readdir order. Nothing here
       depends on the order anyway -- a declaration is reached by name -- but a
       tree that moves between runs makes every later difference harder to
       read. *)
    |> List.sort String.compare
    |> List.map (fun name ->
      let path = Filename.concat core name in
      match In_channel.with_open_bin path In_channel.input_all with
      | text -> Source_map.File.create ~path:(shown name) ~text
      | exception Sys_error message -> failwith message)

(* Asked for once per meta block and call site rather than once per program.
   Sharing one tree is safe because nothing after this mutates it. *)
let parsed =
  lazy
    (List.concat_map
       (fun file ->
         let named = Source_map.File.path file in
         match Scanner.scan_tokens file with
         | Error _ -> raise (Missing (named ^ " does not scan."))
         | Ok tokens ->
           (match Parser.parse tokens with
            | Error (e :: _) ->
              raise
                (Missing
                   (Printf.sprintf
                      "%s does not parse: %s %s"
                      named
                      (Ast.locate ~entry:named e.Parser.span)
                      e.Parser.message))
            | Error [] -> raise (Missing (named ^ " does not parse."))
            | Ok program -> program))
       (files ()))

let program () = Lazy.force parsed
