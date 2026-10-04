
let types : (string * int) list = []

(* The prose is here because the signature is here: a native has no declaration
   to carry a doc comment, and a reference that leaves out `print` is a reference
   with a hole in the middle of it. An empty doc is what says a name is the
   compiler's own business rather than part of the language's surface, and that
   is what keeps `__parse_int` out of the reference. *)
let methods
  : (string * string * string * (unit -> Types.infer_ty list * Types.infer_ty)) list
  =
  [ ( "string"
    , "bytes"
    , "The UTF-8 bytes of the string, which is what it is stored as."
    , fun () -> [ Types.IStr ], Types.iarray Types.IByte )
    (* The one way a string becomes an identifier, checked. *)
  ; ( "string"
    , "as_name"
    , "The string as an identifier, for a meta block building a declaration. The \
       string must spell one."
    , fun () -> [ Types.IStr ], Types.iname )
  ; "string", "to_upper", "The string in upper case.", (fun () -> [ Types.IStr ], Types.IStr)
  ; "string", "to_lower", "The string in lower case.", (fun () -> [ Types.IStr ], Types.IStr)
  ; "char", "to_upper", "The character in upper case.", (fun () -> [ Types.IChr ], Types.IChr)
  ; "char", "to_lower", "The character in lower case.", (fun () -> [ Types.IChr ], Types.IChr)
  ; ( "int"
    , "to_float"
    , "The integer as a float. Exact up to the float's precision."
    , fun () -> [ Types.IInt ], Types.IFloat )
  ; ( "float"
    , "to_int"
    , "The float truncated towards zero."
    , fun () -> [ Types.IFloat ], Types.IInt )
  ; "byte", "to_int", "The byte as a number from 0 to 255.", (fun () -> [ Types.IByte ], Types.IInt)
  ; ( "int"
    , "to_byte"
    , "The integer's lowest eight bits as a byte, so 256 is 0 and -1 is 255."
    , fun () -> [ Types.IInt ], Types.IByte )
  ]

(* No HM type describes these. A call is checked structurally; a bare reference
   is a function of no arguments, which stops one being passed around. *)
let variadic : (string * (unit -> Types.infer_ty)) list =
  [     Ast.generated [ "meta"; "emit" ], (fun () -> Types.IUnit)
  ; Ast.generated [ "meta"; "value" ], (fun () -> Types.IUnit)
      ; Ast.generated [ "meta"; "code" ], (fun () -> Types.INamed (Core.syntax "Expr", []))
  ; ( Ast.generated [ "meta"; "code_stmts" ]
    , fun () -> Types.INamed (Core.list, [ Types.INamed (Core.syntax "Stmt", []) ]) )
  ; Ast.generated [ "meta"; "code_decl" ], (fun () -> Types.INamed (Core.syntax "Decl", []))
  ]

(* Which test a `cx test` process is for. The runner defines it per process;
   anywhere else it is -1, which asks `std/test/Test` for the list instead. *)
let selected_test = "__test_selected"

(* The size `cx bench` runs a benchmark at in this process; 0 anywhere else. *)
let bench_size = "__bench_size"

let functions : (string * string * (unit -> Types.infer_ty list * Types.infer_ty)) list =
  [ selected_test, "", (fun () -> [], Types.IInt)
  ; bench_size, "", (fun () -> [], Types.IInt)
  ; ("__write_out", "", fun () -> [ Types.IStr ], Types.IUnit)
  ; ("__flush_out", "", fun () -> [], Types.IUnit)
  ; ( "__file_open"
    , ""
    , fun () -> [ Types.IStr; Types.IInt ], Types.ITuple [ Types.IInt; Types.IInt; Types.IStr ] )
  ; ( "__file_read"
    , ""
    , fun () ->
        [ Types.IInt; Types.IInt ], Types.ITuple [ Types.IInt; Types.iarray Types.IByte; Types.IStr ]
    )
  ; ( "__file_write"
    , ""
    , fun () -> [ Types.IInt; Types.iarray Types.IByte ], Types.ITuple [ Types.IInt; Types.IStr ] )
  ; ("__file_close", "", fun () -> [ Types.IInt ], Types.ITuple [ Types.IInt; Types.IStr ])
  ; ( "__stdin_read"
    , ""
    , fun () -> [ Types.IInt ], Types.ITuple [ Types.IInt; Types.iarray Types.IByte; Types.IStr ] )
  ; ( "__utf8"
    , ""
    , fun () -> [ Types.iarray Types.IByte ], Types.ITuple [ Types.IInt; Types.IStr ] )
  ; ("__write_err", "", fun () -> [ Types.IStr ], Types.IUnit)
  ; ( "str"
    , "The value as `print` writes it: through its `Display` impl if it has one, \
       then its `Debug` impl, and otherwise its structure, each part as `debug` \
       writes it."
    , fun () -> [ Types.fresh () ], Types.IStr )
  ; ( "debug"
    , "The value in the form that tells values apart: through its `Debug` impl \
       if it has one, and otherwise its structure, with a string or a char \
       quoted and a byte as its number."
    , fun () -> [ Types.fresh () ], Types.IStr )
  ; ("__written", "", fun () -> [ Types.fresh () ], Types.IStr)
  ; ( Ast.generated [ "meta"; "moduleof" ]
    , ""
    , fun () -> [ Types.IStr; Types.IStr ], Types.ISum (Core.reflect "Module", []) )
  ; ("__span_generated", "", fun () -> [], Types.ispan)
  ; ( "compile_error"
    , "Stops the build with the message, reported at the span: how a meta block \
       says that what it was asked to generate from is wrong, where the mistake is."
    , fun () -> [ Types.ispan; Types.IStr ], Types.fresh () )
  ; ("__fixed", "", fun () -> [ Types.IFloat; Types.IInt ], Types.IStr)
  ; "ord", "The character's Unicode code point.", (fun () -> [ Types.IChr ], Types.IInt)
  ; ( "chr"
    , "The character at a Unicode code point. Panics if there is none."
    , fun () -> [ Types.IInt ], Types.IChr )
  (* -1, 0 or 1, or 2 for two floats that do not compare. *)
  ; ( "__order"
    , ""
    , fun () ->
        let t = Types.fresh () in
        [ t; t ], Types.IInt )
  ; ("__parse_int", "", fun () -> [ Types.IStr ], Types.ITuple [ Types.IBool; Types.IInt ])
  ; ("__parse_float", "", fun () -> [ Types.IStr ], Types.ITuple [ Types.IBool; Types.IFloat ])
  ; ( "panic"
    , "Stops the program with a message. Nothing after the call runs, and no \
       handler resumes it."
    , fun () -> [ Types.IStr ], Types.IUnit )
  ; ( "same"
    , "Whether the two are the same value rather than equal ones -- identity, \
       not `==`."
    , fun () ->
        let t = Types.fresh () in
        [ t; t ], Types.IBool )
  (* What a derived `Eq` reaches, through an impl so a type has to ask. *)
  ; ( "__structural_eq"
    , ""
    , fun () ->
        let t = Types.fresh () in
        [ t; t ], Types.IBool )
    (* A new array of the slots from the start up to the stop, which needs no
       value to fill it with: `Array<T>(n, v)` does, and an empty array has
       none to lend. *)
  ; ( "__array_copy"
    , ""
    , fun () ->
        let t = Types.fresh () in
        [ Types.iarray t; Types.IInt; Types.IInt ], Types.iarray t )
    (* A longer array holding the old one's slots, and the value in the rest. *)
  ; ( "__array_grow"
    , ""
    , fun () ->
        let t = Types.fresh () in
        [ Types.iarray t; Types.IInt; t ], Types.iarray t )
  ]
  @ System.functions
  @ Numeric.functions

(* ---- values ---- *)

let ascii f c = if Uchar.is_char c then Uchar.of_char (f (Uchar.to_char c)) else c
let upper = ascii Char.uppercase_ascii
let lower = ascii Char.lowercase_ascii

(* What a literal accepts, and nothing `int_of_string` adds to it: no `0x`, no
   `_`, no leading `+`. *)
let numeral ~fraction text =
  let digits from =
    let rec go i =
      if i < String.length text && text.[i] >= '0' && text.[i] <= '9' then go (i + 1) else i
    in
    let stop = go from in
    if stop = from then None else Some stop
  in
  let start = if String.length text > 0 && text.[0] = '-' then 1 else 0 in
  let length = String.length text in
  let exponent at =
    at < length
    && (text.[at] = 'e' || text.[at] = 'E')
    &&
    let sign = if at + 1 < length && (text.[at + 1] = '+' || text.[at + 1] = '-') then 1 else 0 in
    digits (at + 1 + sign) = Some length
  in
  match digits start with
  | Some stop when stop = length -> true
  | Some stop when fraction && text.[stop] = '.' ->
    (match digits (stop + 1) with
     | Some stop -> stop = length || exponent stop
     | None -> false)
  | Some stop when fraction -> exponent stop
  | _ -> false

(* Open files, by the handle the program holds. A handle is never reused, so a
   file closed twice, or used after it was closed, is simply not found. *)
type file =
  | Reading of In_channel.t
  | Writing of Out_channel.t

let files : (int, file) Hashtbl.t = Hashtbl.create 8
let next_file = ref 0

(* A status the library turns into an `IoError`: 0 is success, then NotFound,
   Denied and Other. Read off the system's message, which is all `Sys_error`
   carries. *)
let status_of message =
  let mentions part =
    let n = String.length part and m = String.length message in
    let rec at i = i + n <= m && (String.sub message i n = part || at (i + 1)) in
    at 0
  in
  if mentions "No such file" then 1 else if mentions "Permission denied" then 2 else 3

let bytes_of = System.bytes_of
let byte_array = System.byte_array

let quoted ~mark text =
  let buf = Buffer.create (String.length text + 2) in
  Buffer.add_char buf mark;
  String.iter
    (fun c ->
      match c with
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\r' -> Buffer.add_string buf "\\r"
      | c when Char.equal c mark -> Buffer.add_char buf '\\'; Buffer.add_char buf c
      | c -> Buffer.add_char buf c)
    text;
  Buffer.add_char buf mark;
  Buffer.contents buf

(* What `str` and `debug` write. A record or variant whose type implements
   `Display` or `Debug` is written by that impl, found by the name its method
   was given rather than chosen where the call was checked: a part of a value
   is printed wherever it sits, and only the value knows its type there. The
   method is called directly, so one that performs an effect cannot be
   reached from here. *)
let written ~globals =
  let method_of name trait method_ =
    match Value.lookup globals (Ast.generated [ name; trait; method_ ]) with
    | Some { contents = Value.Fn f } -> Some f
    | _ -> None
  in
  let called span (f : Value.fn) v =
    if f.Value.arity <> Some 1
    then Value.fail span "'%s' performs an effect, so it cannot write a printed value." f.Value.name;
    match f.Value.apply span [ v ] with
    | Value.Str text -> Utf8.encode text
    | other -> Value.fail span "'%s' answered %s rather than a string." f.Value.name (Value.type_name other)
  in
  let rec shown span mode (v : Value.value) =
    let declared =
      match v with
      | Value.Record (Some name, _) | Value.Variant (Some name, _, _) -> Some name
      | _ -> None
    in
    let impl =
      Option.bind declared (fun name ->
        match mode with
        | `Display ->
          (match method_of name Core.display "fmt" with
           | Some f -> Some f
           | None -> method_of name Core.debug "debug")
        | `Debug -> method_of name Core.debug "debug")
    in
    match impl, v with
    | Some f, _ -> called span f v
    | None, Value.Str s -> if mode = `Debug then quoted ~mark:'"' (Utf8.encode s) else Utf8.encode s
    | None, Value.Chr c ->
      let buf = Buffer.create 4 in
      Buffer.add_utf_8_uchar buf c;
      if mode = `Debug then quoted ~mark:'\'' (Buffer.contents buf) else Buffer.contents buf
    | None, Value.Object (data, _) -> shown span mode data
    | None, v -> form span v
  (* The builtin form: the structure, each part as `debug` writes it. *)
  and form span (v : Value.value) =
    let part = shown span `Debug in
    match v with
    | Value.Array items -> "[" ^ String.concat ", " (Array.to_list (Array.map part items)) ^ "]"
    | Value.Tuple items -> "(" ^ String.concat ", " (List.map part items) ^ ")"
    | Value.Variant (_, name, []) -> name
    | Value.Variant (_, name, fields) ->
      name ^ "(" ^ String.concat ", " (List.map (fun (_, v) -> part v) fields) ^ ")"
    | Value.Record (_, fields) ->
      "{ " ^ String.concat ", " (List.map (fun (l, v) -> l ^ ": " ^ part !v) fields) ^ " }"
    | Value.Byte b -> string_of_int (Char.code b)
    | Value.Object (data, _) -> form span data
    | other -> Value.string_of_value other
  in
  shown, form

let stdout_is_terminal = lazy (Unix.isatty Unix.stdout)

(* Line-buffered at a terminal, as C's stdio is, so a line shows when it is
   printed; block-buffered anywhere else, where flushing every line is slow. *)
let to_stdout text =
  print_string text;
  if Lazy.force stdout_is_terminal && String.contains text '\n' then flush stdout

let values ~out ~globals =
  let shown, form = written ~globals in
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
  [ native "__array_copy" (Some 3) (fun span args ->
      match args with
      | [ Value.Array items; Value.Int start; Value.Int stop ] ->
        if start < 0 || stop > Array.length items
        then Value.fail span "__array_copy: %d to %d is outside an array of %d." start stop (Array.length items);
        Value.Array (if stop <= start then [||] else Array.sub items start (stop - start))
      | _ -> Value.fail span "__array_copy takes an array and two bounds.")
  ; native "__array_grow" (Some 3) (fun span args ->
      match args with
      | [ Value.Array items; Value.Int length; fill ] ->
        if length < Array.length items
        then Value.fail span "__array_grow: %d is shorter than an array of %d." length (Array.length items);
        let grown = Array.make length fill in
        Array.blit items 0 grown 0 (Array.length items);
        Value.Array grown
      | _ -> Value.fail span "__array_grow takes an array, a length and a value.")
  ; one "__write_out" (fun span v ->
      match v with
      | Value.Str text ->
        out (Utf8.encode text);
        Value.Unit
      | _ -> Value.fail span "__write_out takes a string.")
  ; native "__flush_out" (Some 0) (fun _ _ ->
      flush stdout;
      Value.Unit)
  ; two "__file_open" (fun span p m ->
      match p, m with
      | Value.Str path, Value.Int mode ->
        let path = Utf8.encode path in
        (match
           match mode with
           | 0 -> Reading (In_channel.open_bin path)
           | 1 -> Writing (Out_channel.open_bin path)
           | _ ->
             Writing
               (Out_channel.open_gen
                  [ Open_wronly; Open_creat; Open_append; Open_binary ]
                  0o644
                  path)
         with
         | file ->
           let handle = !next_file in
           incr next_file;
           Hashtbl.replace files handle file;
           Value.Tuple [ Value.Int 0; Value.Int handle; Value.Str [||] ]
         | exception Sys_error message ->
           Value.Tuple [ Value.Int (status_of message); Value.Int (-1); Value.Str (Utf8.decode message) ])
      | _ -> Value.fail span "__file_open takes a path and a mode.")
  ; two "__file_read" (fun span h m ->
      match h, m with
      | Value.Int handle, Value.Int count ->
        let failed message = Value.Tuple [ Value.Int 3; byte_array ""; Value.Str (Utf8.decode message) ] in
        (match Hashtbl.find_opt files handle with
         | Some (Reading channel) ->
           let buffer = Bytes.create (Int.max 1 count) in
           (* Fewer than asked is not the end; none at all is. *)
           (match In_channel.input channel buffer 0 (Bytes.length buffer) with
            | read -> Value.Tuple [ Value.Int 0; byte_array (Bytes.sub_string buffer 0 read); Value.Str [||] ]
            | exception Sys_error message ->
              Value.Tuple [ Value.Int (status_of message); byte_array ""; Value.Str (Utf8.decode message) ])
         | Some (Writing _) -> failed "The file is open for writing, not reading."
         | None -> failed "The file is closed.")
      | _ -> Value.fail span "__file_read takes a handle and a count.")
  ; two "__file_write" (fun span h d ->
      match h, bytes_of d with
      | Value.Int handle, Some data ->
        let failed message = Value.Tuple [ Value.Int 3; Value.Str (Utf8.decode message) ] in
        (match Hashtbl.find_opt files handle with
         | Some (Writing channel) ->
           (match Out_channel.output_string channel data with
            | () -> Value.Tuple [ Value.Int 0; Value.Str [||] ]
            | exception Sys_error message ->
              Value.Tuple [ Value.Int (status_of message); Value.Str (Utf8.decode message) ])
         | Some (Reading _) -> failed "The file is open for reading, not writing."
         | None -> failed "The file is closed.")
      | _ -> Value.fail span "__file_write takes a handle and bytes.")
  ; one "__stdin_read" (fun span n ->
      match n with
      | Value.Int count ->
        (* A prompt printed before the read would otherwise stay buffered until
           the program has its answer. *)
        flush stdout;
        let buffer = Bytes.create (Int.max 1 count) in
        (match In_channel.input stdin buffer 0 (Bytes.length buffer) with
         | read -> Value.Tuple [ Value.Int 0; byte_array (Bytes.sub_string buffer 0 read); Value.Str [||] ]
         | exception Sys_error message ->
           Value.Tuple [ Value.Int (status_of message); byte_array ""; Value.Str (Utf8.decode message) ])
      | _ -> Value.fail span "__stdin_read takes a count.")
  ; one "__file_close" (fun span h ->
      match h with
      | Value.Int handle ->
        (match Hashtbl.find_opt files handle with
         | Some file ->
           Hashtbl.remove files handle;
           (match
              match file with
              | Reading channel -> In_channel.close channel
              | Writing channel -> Out_channel.close channel
            with
            | () -> Value.Tuple [ Value.Int 0; Value.Str [||] ]
            | exception Sys_error message ->
              Value.Tuple [ Value.Int (status_of message); Value.Str (Utf8.decode message) ])
         | None -> Value.Tuple [ Value.Int 3; Value.Str (Utf8.decode "The file is closed.") ])
      | _ -> Value.fail span "__file_close takes a handle.")
  (* The offset of the first byte that is not part of a character, or -1 and the
     text. *)
  ; one "__utf8" (fun span d ->
      match bytes_of d with
      | Some data ->
        let rec first_bad at =
          if at >= String.length data
          then None
          else (
            let d = String.get_utf_8_uchar data at in
            if Uchar.utf_decode_is_valid d then first_bad (at + Uchar.utf_decode_length d) else Some at)
        in
        (match first_bad 0 with
         | None -> Value.Tuple [ Value.Int (-1); Value.Str (Utf8.decode data) ]
         | Some at -> Value.Tuple [ Value.Int at; Value.Str [||] ])
      | None -> Value.fail span "__utf8 takes bytes.")
  ; one "__write_err" (fun span v ->
      match v with
      | Value.Str text ->
        (* So the two streams interleave in the order the program wrote them. *)
        flush stdout;
        prerr_string (Utf8.encode text);
        flush stderr;
        Value.Unit
      | _ -> Value.fail span "__write_err takes a string.")
  ; one "str" (fun span v -> Value.Str (Utf8.decode (shown span `Display v)))
  ; one "debug" (fun span v -> Value.Str (Utf8.decode (shown span `Debug v)))
  ; one "__written" (fun span v -> Value.Str (Utf8.decode (form span v)))
  ; native "__span_generated" (Some 0) (fun _ _ -> Value.Span Source_map.Span.nowhere)
  ; native selected_test (Some 0) (fun _ _ -> Value.Int (-1))
  ; native bench_size (Some 0) (fun _ _ -> Value.Int 0)
  ; two "compile_error" (fun span at message ->
      match at, message with
      | Value.Span at, Value.Str message ->
        let at =
          match Source_map.Span.view at with
          | Source_map.Span.Nowhere_in_source -> span
          | Source_map.Span.Located _ -> at
        in
        raise (Value.Runtime_error { Value.span = at; message = Utf8.encode message })
      | _ -> Value.fail span "compile_error takes a span and a message.")
  ; two "__fixed" (fun span x digits ->
      match x, digits with
      | Value.Float x, Value.Int digits when digits >= 0 ->
        Value.Str (Utf8.decode (Printf.sprintf "%.*f" digits x))
      | _, Value.Int digits -> Value.fail span "fixed takes a count of digits, not %d." digits
      | _ -> Value.fail span "Cannot apply fixed to these arguments.")
  ; one "ord" (fun span v ->
      match v with
      | Value.Chr c -> Value.Int (Uchar.to_int c)
      | _ -> Value.fail span "Cannot apply ord to these arguments.")
  ; one "chr" (fun span v ->
      match v with
      | Value.Int n when Uchar.is_valid n -> Value.Chr (Uchar.of_int n)
      | Value.Int n -> Value.fail span "%d is not a Unicode scalar value." n
      | _ -> Value.fail span "Cannot apply chr to these arguments.")
  ; two "__order" (fun span a b ->
      let sign c = Value.Int (Int.compare c 0) in
      match a, b with
      | Value.Int x, Value.Int y -> sign (Int.compare x y)
      | Value.Float x, Value.Float y ->
        if Float.is_nan x || Float.is_nan y then Value.Int 2 else sign (Float.compare x y)
      | Value.Str x, Value.Str y -> sign (Utf8.compare x y)
      | Value.Chr x, Value.Chr y -> sign (Uchar.compare x y)
      | Value.Byte x, Value.Byte y -> sign (Char.compare x y)
      | _ -> Value.fail span "__order takes two numbers, strings, chars or bytes of one type.")
  ; one "__parse_int" (fun span v ->
      match v with
      | Value.Str s ->
        let text = Utf8.encode s in
        (match if numeral ~fraction:false text then int_of_string_opt text else None with
         | Some n -> Value.Tuple [ Value.Bool true; Value.Int n ]
         | None -> Value.Tuple [ Value.Bool false; Value.Int 0 ])
      | _ -> Value.fail span "Cannot apply to_int to these arguments.")
  ; one "__parse_float" (fun span v ->
      match v with
      | Value.Str s ->
        let text = Utf8.encode s in
        if numeral ~fraction:true text
        then Value.Tuple [ Value.Bool true; Value.Float (float_of_string text) ]
        else Value.Tuple [ Value.Bool false; Value.Float 0.0 ]
      | _ -> Value.fail span "Cannot apply to_float to these arguments.")
  (* Nothing in Cronyx can raise, so code that must refuse an argument has no
     way to say so without reaching the interpreter's own failure. *)
  ; one "panic" (fun span v ->
      match v with
      | Value.Str s -> Value.fail span "%s" (Utf8.encode s)
      | _ -> Value.fail span "Cannot apply panic to these arguments.")
  ; two "same" (fun _ a b -> Value.Bool (Value.same a b))
  ; one "__upcast" (fun _ v -> v)
  ; two "__structural_eq" (fun _ a b -> Value.Bool (Value.values_equal a b))
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
  ; one (Ast.method_name "string" "to_upper") (fun span v ->
      match v with
      | Value.Str s -> Value.Str (Array.map upper s)
      | _ -> Value.fail span "Cannot apply to_upper to these arguments.")
  ; one (Ast.method_name "string" "to_lower") (fun span v ->
      match v with
      | Value.Str s -> Value.Str (Array.map lower s)
      | _ -> Value.fail span "Cannot apply to_lower to these arguments.")
  ; one (Ast.method_name "char" "to_upper") (fun span v ->
      match v with
      | Value.Chr c -> Value.Chr (upper c)
      | _ -> Value.fail span "Cannot apply to_upper to these arguments.")
  ; one (Ast.method_name "char" "to_lower") (fun span v ->
      match v with
      | Value.Chr c -> Value.Chr (lower c)
      | _ -> Value.fail span "Cannot apply to_lower to these arguments.")
  ; one (Ast.method_name "int" "to_float") (fun span v ->
      match v with
      | Value.Int n -> Value.Float (float_of_int n)
      | _ -> Value.fail span "Cannot apply to_float to these arguments.")
  ; one (Ast.method_name "byte" "to_int") (fun span v ->
      match v with
      | Value.Byte b -> Value.Int (Char.code b)
      | _ -> Value.fail span "Cannot apply to_int to these arguments.")
  ; one (Ast.method_name "int" "to_byte") (fun span v ->
      match v with
      | Value.Int n -> Value.Byte (Char.chr (n land 0xff))
      | _ -> Value.fail span "Cannot apply to_byte to these arguments.")
  ; one (Ast.method_name "float" "to_int") (fun span v ->
      match v with
      | Value.Float x when Float.is_finite x && Float.abs x < 0x1p62 ->
        Value.Int (Float.to_int x)
      | Value.Float x ->
        Value.fail span "%s has no int value." (Token.float_to_string x)
      | _ -> Value.fail span "Cannot apply to_int to these arguments.")
  ; one (Ast.method_name "string" "bytes") (fun span v ->
      match v with
      | Value.Str s ->
        let bytes = Utf8.encode s in
        Value.Array (Array.init (String.length bytes) (fun i -> Value.Byte bytes.[i]))
      | _ -> Value.fail span "Cannot apply bytes to these arguments.")
  ]
  @ System.values ~native:(fun name arity apply -> native name (Some arity) apply)
  @ Numeric.values ~native:(fun name arity apply -> native name (Some arity) apply)

let env ~out =
  let env = Value.new_env None in
  List.iter (fun (name, v) -> Value.define env name v) (values ~out ~globals:env);
  env
