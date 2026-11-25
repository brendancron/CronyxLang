(* A diagnostic drawn as a frame. Every part of the frame is unconditional: the
   rows between the rules vary, the rules themselves do not, so no absent field
   can delete a line and leave the frame hanging open. *)

type palette =
  { bold : string
  ; red : string
  ; cyan : string
  ; magenta : string
  ; off : string
  }

let plain = { bold = ""; red = ""; cyan = ""; magenta = ""; off = "" }

let ansi =
  { bold = "\027[1m"
  ; red = "\027[1;31m"
  ; cyan = "\027[36m"
  ; magenta = "\027[35m"
  ; off = "\027[0m"
  }

(* A tab is a stop every eight columns, counted the way a terminal draws them
   rather than in bytes, so a line holding wide or combining characters and the
   underline beneath it still agree on where a column is. *)
let tab_width = 8
let tab = Uchar.of_char '\t'

let laid_out text =
  let buf = Buffer.create (String.length text) in
  let columns = ref 0 in
  Array.iter
    (fun scalar ->
      if Uchar.equal scalar tab
      then (
        let step = tab_width - (!columns mod tab_width) in
        Buffer.add_string buf (String.make step ' ');
        columns := !columns + step)
      else (
        Buffer.add_utf_8_uchar buf scalar;
        columns := !columns + Char_width.of_uchar scalar))
    (Utf8.decode text);
  Buffer.contents buf, !columns

let slice text ~from ~upto =
  let limit = String.length text in
  let from = max 0 (min from limit) in
  let upto = max from (min upto limit) in
  String.sub text from (upto - from)

let frame ~palette ~entry (e : Diagnostic.error) =
  let buf = Buffer.create 256 in
  let add = Buffer.add_string buf in
  let located = Source_map.Span.view e.Diagnostic.span in
  (* As wide as the line number that will sit in it, so the rules and the source
     line hang off the same column. *)
  let gutter =
    match located with
    | Source_map.Span.Nowhere_in_source -> " "
    | Source_map.Span.Located l ->
      String.make (String.length (string_of_int l.Source_map.Span.line)) ' '
  in
  let rule text = add (Printf.sprintf "%s %s%s%s\n" gutter palette.cyan text palette.off) in
  add
    (Printf.sprintf
       "%s×%s %s%s error: %s%s\n"
       palette.red
       palette.off
       palette.bold
       (Diagnostic.stage_name e.Diagnostic.stage)
       e.Diagnostic.message
       palette.off);
  (match located with
   | Source_map.Span.Nowhere_in_source -> rule "┌─ (no source location)"
   | Source_map.Span.Located l ->
     let path = Ast.shown_path ~entry (Source_map.File.path l.Source_map.Span.file) in
     rule (Printf.sprintf "┌─ %s:%d:%d" path l.Source_map.Span.line l.Source_map.Span.col);
     let text = l.Source_map.Span.line_text in
     let _, before =
       laid_out (slice text ~from:0 ~upto:l.Source_map.Span.underline_from)
     in
     let _, marked =
       laid_out
         (slice
            text
            ~from:l.Source_map.Span.underline_from
            ~upto:l.Source_map.Span.underline_to)
     in
     let marked = max 1 marked in
     rule "│";
     add
       (Printf.sprintf
          "%d %s│%s %s\n"
          l.Source_map.Span.line
          palette.cyan
          palette.off
          (fst (laid_out text)));
     add
       (Printf.sprintf
          "%s %s│%s %s%s%s%s\n"
          gutter
          palette.cyan
          palette.off
          (String.make before ' ')
          palette.magenta
          (String.make marked '~')
          palette.off));
  rule "└─";
  Option.iter (fun note -> add (Printf.sprintf "%s %snote:%s %s\n" gutter palette.bold palette.off note)) e.Diagnostic.note;
  Buffer.contents buf

let color_wanted channel =
  match Sys.getenv_opt "NO_COLOR" with
  | Some value when not (String.equal value "") -> false
  | _ -> Out_channel.isatty channel

let error ~entry e = frame ~palette:plain ~entry e

let emit ~entry errors =
  let palette = if color_wanted stderr then ansi else plain in
  List.iter (fun e -> prerr_string (frame ~palette ~entry e)) errors;
  match errors with
  | [] | [ _ ] -> ()
  | many ->
    prerr_string
      (Printf.sprintf
         "%s×%s %s%d errors found.%s\n"
         palette.red
         palette.off
         palette.bold
         (List.length many)
         palette.off)
