(* Each pass keeps its own error record; this is what they are widened to at
   the boundary, so the sequence of passes can be written once. *)

type stage =
  | Manifest
  | Scan
  | Parse
  | Load
  | Meta
  | Desugar
  | Type
  | Type_mono
  | Resolve
  | Reflect
  | Cps
  | Verify
  | Runtime

type error =
  { stage : stage
  ; span : Ast.span
  ; message : string
  }

let stage_name = function
  | Manifest -> "Manifest"
  | Scan -> "Scan"
  | Parse -> "Parse"
  | Load -> "Load"
  | Meta -> "Meta"
  | Desugar -> "Desugar"
  | Type -> "Type"
  | Type_mono -> "Type monomorphize"
  | Resolve -> "Resolve"
  | Reflect -> "Reflect"
  | Cps -> "CPS"
  | Verify -> "Verify"
  | Runtime -> "Runtime"

(* A program the compiler rejected is the user's fault; one that got past the
   checker and then broke is the compiler's. *)
let exit_code = function
  | Manifest | Scan | Parse | Load | Meta | Desugar | Type | Type_mono | Resolve
  | Reflect -> 65
  | Cps | Verify | Runtime -> 70

(* A name holding `#` was made by the compiler -- a module or package prefix,
   the function a local type belongs to, a template's copy -- and the scanner
   produces none, so every one in a message is shown as it was written. A
   copy's number is dropped with its prefix, or `fib#0` would read as `0`. *)
let as_written message =
  let is_name c =
    match c with
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '#' -> true
    | _ -> false
  in
  let is_number part = part <> "" && String.for_all (fun c -> c >= '0' && c <= '9') part in
  let shorten word =
    if not (String.contains word '#')
    then word
    else (
      match List.rev (String.split_on_char '#' word) |> List.drop_while is_number with
      | last :: _ when last <> "" -> last
      | _ -> word)
  in
  let out = Buffer.create (String.length message) in
  let n = String.length message in
  let rec go i =
    if i < n
    then
      if is_name message.[i]
      then (
        let j = ref i in
        while !j < n && is_name message.[!j] do
          incr j
        done;
        Buffer.add_string out (shorten (String.sub message i (!j - i)));
        go !j)
      else (
        Buffer.add_char out message.[i];
        go (i + 1))
  in
  go 0;
  Buffer.contents out

let at stage span message = { stage; span; message = as_written message }
let one stage span message = Error [ at stage span message ]
