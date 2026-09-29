(* Text a span can point into, and the spans themselves. A span is abstract and
   carries its file, so resolving one to a line needs no lookup table and cannot
   miss: [Span.view] is total, which is what stops a diagnostic from rendering a
   frame with the source line silently missing. *)

module File = struct
  type t =
    { path : string
    ; text : string
    ; line_starts : int array (* byte offset of each line's first character *)
    }

  let line_starts text =
    let starts = ref [ 0 ] in
    String.iteri (fun offset c -> if c = '\n' then starts := (offset + 1) :: !starts) text;
    Array.of_list (List.rev !starts)

  let create ~path ~text = { path; text; line_starts = line_starts text }

  let load path =
    match open_in_bin path with
    | exception Sys_error message -> Error message
    | channel ->
      let text =
        Fun.protect
          ~finally:(fun () -> close_in channel)
          (fun () -> really_input_string channel (in_channel_length channel))
      in
      Ok (create ~path ~text)

  let path file = file.path
  let text file = file.text

  (* Largest index whose line starts at or before [offset]. *)
  let line_index file offset =
    let low = ref 0 and high = ref (Array.length file.line_starts - 1) in
    while !low < !high do
      let middle = (!low + !high + 1) / 2 in
      if file.line_starts.(middle) <= offset then low := middle else high := middle - 1
    done;
    !low

  let line_bounds file index =
    let start = file.line_starts.(index) in
    let stop =
      if index + 1 < Array.length file.line_starts
      then file.line_starts.(index + 1) - 1
      else String.length file.text
    in
    let stop = if stop > start && file.text.[stop - 1] = '\r' then stop - 1 else stop in
    start, stop

  let line_text file index =
    let start, stop = line_bounds file index in
    String.sub file.text start (stop - start)
end

module Span = struct
  type t =
    | Nowhere
    | Range of
        { file : File.t
        ; lo : int
        ; hi : int
        }

  (* Everything the renderer needs, already resolved against the file, so no
     consumer repeats the clamping this module does once. *)
  type located =
    { file : File.t
    ; line : int (* 1-based *)
    ; col : int (* 1-based, in bytes from the start of the line *)
    ; line_text : string
    ; underline_from : int (* byte offset into [line_text] *)
    ; underline_to : int (* exclusive, never past the end of [line_text] *)
    }

  type view =
    | Located of located
    | Nowhere_in_source

  let nowhere = Nowhere

  let of_range file ~lo ~hi =
    let limit = String.length (File.text file) in
    let lo = max 0 (min lo limit) in
    let hi = max lo (min hi limit) in
    Range { file; lo; hi }

  let join a b =
    match a, b with
    | Range a, Range b when a.file == b.file -> Range { a with hi = max a.hi b.hi }
    | Range _, _ -> a
    | Nowhere, _ -> b

  let view = function
    | Nowhere -> Nowhere_in_source
    | Range { file; lo; hi } ->
      let index = File.line_index file lo in
      let start, stop = File.line_bounds file index in
      let text = File.line_text file index in
      (* A span reaching past its first line underlines to the end of that line;
         the frame shows one line, so there is nothing further to point at. *)
      let underline_to = (min hi stop) - start in
      let underline_from = lo - start in
      Located
        { file
        ; line = index + 1
        ; col = underline_from + 1
        ; line_text = text
        ; underline_from
        ; underline_to = max underline_from underline_to
        }

  let path = function
    | Nowhere -> ""
    | Range { file; _ } -> File.path file
end
