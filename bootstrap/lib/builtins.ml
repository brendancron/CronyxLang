
let types : (string * int) list = []

let methods : (string * string * (unit -> Types.infer_ty list * Types.infer_ty)) list =
  [ "string", "bytes", (fun () -> [ Types.IStr ], Types.iarray Types.IByte)
    (* The one way a string becomes an identifier, checked. *)
  ; "string", "as_name", (fun () -> [ Types.IStr ], Types.iname)
  ]

(* No HM type describes these. A call is checked structurally; a bare reference
   is a function of no arguments, which stops one being passed around. *)
let variadic : (string * (unit -> Types.infer_ty)) list =
  [     Ast.generated [ "meta"; "emit" ], (fun () -> Types.IUnit)
  ; Ast.generated [ "meta"; "value" ], (fun () -> Types.IUnit)
      ; Ast.generated [ "meta"; "code" ], (fun () -> Types.icode)
  ]

(* Which test a `cx test` process is for. Only that runner defines it. *)
let selected_test = Ast.generated [ "test"; "selected" ]

let functions : (string * (unit -> Types.infer_ty list * Types.infer_ty)) list =
  [ "clock", (fun () -> [], Types.IFloat)
  ; selected_test, (fun () -> [], Types.IInt)
  ; ("print", fun () -> [ Types.fresh () ], Types.IUnit)
  ; ("str", fun () -> [ Types.fresh () ], Types.IStr)
  ; ("ord", fun () -> [ Types.IChr ], Types.IInt)
  ; ( "same"
    , fun () ->
        let t = Types.fresh () in
        [ t; t ], Types.IBool )
  (* What a derived `Eq` reaches, through an impl so a type has to ask. *)
  ; "readfile", (fun () -> [ Types.IStr ], Types.IStr)
  ; "writefile", (fun () -> [ Types.IStr; Types.IStr ], Types.IUnit)
  ; ( "__structural_eq"
    , fun () ->
        let t = Types.fresh () in
        [ t; t ], Types.IBool )
  ]

(* ---- values ---- *)

(* A relative path is relative to the file that wrote the call, the way an
   import and an `embed` are. Where the program was started from is not
   something the source can see. *)
let beside (span : Ast.span) path =
  let from = Source_map.Span.path span in
  if Filename.is_relative path && not (String.equal from "")
  then Filename.concat (Filename.dirname from) path
  else path

let values ~out =
  let native name arity apply = name, Value.Fn { Value.name; arity; apply } in
  let two name f =
    native name (Some 2) (fun span args ->
      match args with
      | [ a; b ] -> f span a b
      | _ -> Value.fail span "Cannot apply %s to these arguments." name)
  in
  let one name f =
    native name (Some 1) (fun span args ->
      match args with
      | [ a ] -> f span a
      | _ -> Value.fail span "Cannot apply %s to these arguments." name)
  in
  [ one "print" (fun _ v ->
      out (Value.string_of_value v);
      out "\n";
      Value.Unit)
  ; one "str" (fun _ v -> Value.Str (Utf8.decode (Value.string_of_value v)))
  ; one "ord" (fun span v ->
      match v with
      | Value.Chr c -> Value.Int (Uchar.to_int c)
      | _ -> Value.fail span "Cannot apply ord to these arguments.")
  ; two "same" (fun _ a b -> Value.Bool (Value.same a b))
  ; two "__structural_eq" (fun _ a b -> Value.Bool (Value.values_equal a b))
  ; one "readfile" (fun span v ->
      match v with
      | Value.Str path ->
        let written = Utf8.encode path in
        let resolved = beside span written in
        Inputs.record resolved;
        (match In_channel.with_open_bin resolved In_channel.input_all with
         | contents -> Value.Str (Utf8.decode contents)
         (* The path as written, the way `embed` reports one: what the reader
            has in front of them is not where it resolved to. *)
         | exception Sys_error _ -> Value.fail span "Cannot read '%s'." written)
      | _ -> Value.fail span "readfile takes a path.")
  ; two "writefile" (fun span p v ->
      match p, v with
      | Value.Str path, Value.Str contents ->
        let written = Utf8.encode path in
        (match
           Out_channel.with_open_bin (beside span written) (fun channel ->
             Out_channel.output_string channel (Utf8.encode contents))
         with
         | () -> Value.Unit
         | exception Sys_error _ -> Value.fail span "Cannot write '%s'." written)
      | _ -> Value.fail span "writefile takes a path and its contents.")
  ; native "clock" (Some 0) (fun _ _ -> Value.Float (Sys.time ()))
  ; one (Ast.method_name "string" "as_name") (fun span v ->
      match v with
      | Value.Str s ->
        let text = Utf8.encode s in
        let usable =
          String.length text > 0
          && (match text.[0] with
              | 'a' .. 'z' | 'A' .. 'Z' | '_' -> true
              | _ -> false)
          && String.for_all
               (function
                 | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
                 | _ -> false)
               text
        in
        if usable
        then Value.Name text
        else Value.fail span "'%s' cannot be a name." text
      | _ -> Value.fail span "Cannot apply as_name to these arguments.")
  ; one (Ast.method_name "string" "bytes") (fun span v ->
      match v with
      | Value.Str s ->
        let bytes = Utf8.encode s in
        Value.Array (Array.init (String.length bytes) (fun i -> Value.Byte bytes.[i]))
      | _ -> Value.fail span "Cannot apply bytes to these arguments.")
  ]

let env ~out =
  let env = Value.new_env None in
  List.iter (fun (name, v) -> Value.define env name v) (values ~out);
  env
