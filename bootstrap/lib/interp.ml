open Value

exception Return_value of value * Ast.span

(* Caught by the loop it leaves, which is always the innermost: the checker
   refuses a `break` with anything else in between. *)
exception Break_loop
exception Continue_loop

(* Tail calls. A loop written as recursion -- what a run's transform makes of
   a loop holding a split -- ends every step by calling the next, so without
   them each step runs inside the last, and the stack -- and every local each
   step held -- grows until the program ends. A function whose body ends in a
   call hands the call to whoever called it instead of making it: [tail] says
   the statement being run is in that position, and [pending] holds the call,
   which the caller makes. *)
let tail = ref false

type pending_call =
  { p_fn : Value.fn
  ; p_args : Value.value list
  ; p_discards : bool
  ; p_span : Ast.span
  }

let pending : pending_call option ref = ref None

(* The function [call] is about to enter. Only a call made through [call] is
   followed by a [bounce]; a builtin applying a closure directly is not, so the
   closure makes the call it would have handed back itself. *)
let entering : Value.fn option ref = ref None

let not_tail f =
  let outer = !tail in
  tail := false;
  Fun.protect ~finally:(fun () -> tail := outer) f

let compare_ordered op x y =
  match op with
  | Ast.Less -> x < y
  | Ast.Less_equal -> x <= y
  | Ast.Greater -> x > y
  | _ -> x >= y

let as_bool span = function
  | Bool b -> b
  | v -> fail span "Expected a bool condition, got %s." (type_name v)

(* Mixed operands cannot reach here: there is no implicit widening. *)
let eval_binop span (op : Ast.binop) a b =
  match op, a, b with
  | Ast.Add, Int x, Int y -> Int (x + y)
  | Ast.Add, Float x, Float y -> Float (x +. y)
  | Ast.Add, Str x, Str y -> Str (Array.append x y)
  | Ast.Sub, Int x, Int y -> Int (x - y)
  | Ast.Sub, Float x, Float y -> Float (x -. y)
  | Ast.Mul, Int x, Int y -> Int (x * y)
  | Ast.Mul, Float x, Float y -> Float (x *. y)
  | Ast.Div, Int _, Int 0 -> fail span "Division by zero."
  | Ast.Mod, Int _, Int 0 -> fail span "Division by zero."
  | Ast.Mod, Int x, Int y -> Int (x mod y)
  | Ast.Mod, Float x, Float y -> Float (Float.rem x y)
  | Ast.Div, Int x, Int y -> Int (x / y)
  | Ast.Div, Float x, Float y -> Float (x /. y)
  | Ast.Less, Int x, Int y -> Bool (x < y)
  | Ast.Less, Float x, Float y -> Bool (x < y)
  | Ast.Less_equal, Int x, Int y -> Bool (x <= y)
  | Ast.Less_equal, Float x, Float y -> Bool (x <= y)
  | Ast.Greater, Int x, Int y -> Bool (x > y)
  | Ast.Greater, Float x, Float y -> Bool (x > y)
  | Ast.Greater_equal, Int x, Int y -> Bool (x >= y)
  | Ast.Greater_equal, Float x, Float y -> Bool (x >= y)
  (* A scalar value orders by code point, an octet by its byte. *)
  | (Ast.Less | Ast.Less_equal | Ast.Greater | Ast.Greater_equal), Chr x, Chr y ->
    Bool (compare_ordered op (Uchar.to_int x) (Uchar.to_int y))
  | (Ast.Less | Ast.Less_equal | Ast.Greater | Ast.Greater_equal), Byte x, Byte y ->
    Bool (compare_ordered op (Char.code x) (Char.code y))
  | (Ast.Less | Ast.Less_equal | Ast.Greater | Ast.Greater_equal), Str x, Str y ->
    Bool (compare_ordered op (Utf8.compare x y) 0)
  | Ast.Bit_and, Int x, Int y -> Int (x land y)
  | Ast.Bit_or, Int x, Int y -> Int (x lor y)
  | Ast.Bit_xor, Int x, Int y -> Int (x lxor y)
  | Ast.Bit_and, Byte x, Byte y -> Byte (Char.chr (Char.code x land Char.code y))
  | Ast.Bit_or, Byte x, Byte y -> Byte (Char.chr (Char.code x lor Char.code y))
  | Ast.Bit_xor, Byte x, Byte y -> Byte (Char.chr (Char.code x lxor Char.code y))
  | (Ast.Shl | Ast.Shr), _, Int n when n < 0 -> fail span "Cannot shift by %d, which is negative." n
  (* OCaml leaves a shift by the word size or more unspecified; past every bit,
     a left shift has shifted them all out and a right shift has copied the
     sign into all of them. *)
  | Ast.Shl, Int x, Int n -> Int (if n >= Sys.int_size then 0 else x lsl n)
  | Ast.Shr, Int x, Int n -> Int (if n >= Sys.int_size then (if x < 0 then -1 else 0) else x asr n)
  | Ast.Shl, Byte x, Int n -> Byte (Char.chr (if n >= 8 then 0 else (Char.code x lsl n) land 0xff))
  | Ast.Shr, Byte x, Int n -> Byte (Char.chr (if n >= 8 then 0 else Char.code x lsr n))
  | Ast.Equal, _, _ -> Bool (values_equal span a b)
  | Ast.Not_equal, _, _ -> Bool (not (values_equal span a b))
  | _ ->
    fail
      span
      "Operator is not defined for %s and %s."
      (type_name a)
      (type_name b)

let as_array span = function
  | Array items -> items
  | v -> fail span "Expected an array, got %s." (type_name v)

let as_text span = function
  | Str scalars -> scalars
  | v -> fail span "Expected a string, got %s." (type_name v)

let as_index span = function
  | Int i -> i
  | v -> fail span "Expected an int index, got %s." (type_name v)

let in_bounds span items i =
  if i < 0 || i >= Array.length items
  then fail span "Index %d is out of bounds for length %d." i (Array.length items);
  i

let nominal (ty : Types.ty) =
  match ty with
  | Types.Named (name, _) | Types.Sum (name, _) -> Some name
  | _ -> None

let rec eval env (e : Ast.resolved_expr) : value =
  let span = e.Ast.span in
  match e.Ast.it with
  | `Lambda (params, _, body) -> closure env "fn" params body
  | `Int n -> Int n
  | `Float n -> Float n
  | `Str s -> Str s
  | `Name n -> Name n
  | `Bytes b -> Array (Array.init (String.length b) (fun i -> Byte b.[i]))
  | `Char c -> Chr c
  | `Bool b -> Bool b
  | `Unit -> Unit
  | `Var name ->
    (match lookup env name with
     | Some r -> !r
     | None -> fail span "Undefined variable '%s'." name)
  | `Assign (name, v) ->
    let value = eval env v in
    (match lookup env name with
     | Some r ->
       r := value;
       value
     | None -> fail span "Undefined variable '%s'." name)
  | `Unop (Ast.Neg, a) ->
    (match eval env a with
     | Int n -> Int (-n)
     | Float n -> Float (-.n)
     | v -> fail span "Cannot negate %s." (type_name v))
  | `Unop (Ast.Not, a) -> Bool (not (as_bool span (eval env a)))
  | `Unop (Ast.Bit_not, a) ->
    (match eval env a with
     | Int n -> Int (lnot n)
     | Byte b -> Byte (Char.chr (lnot (Char.code b) land 0xff))
     | v -> fail span "Cannot apply '~' to %s." (type_name v))
  | `Binop (op, a, b) ->
    let a = eval env a in
    let b = eval env b in
    eval_binop span op a b
  | `And (a, b) ->
    if as_bool span (eval env a) then Bool (as_bool span (eval env b)) else Bool false
  | `Or (a, b) ->
    if as_bool span (eval env a) then Bool true else Bool (as_bool span (eval env b))
  | `Call (callee, args) ->
    let f = eval env callee in
    call span f (eval_all env args)
  | `Object (data, id, vtable) ->
    Object
      ( eval env data
      , { made_from = id.Ast.made_from; equal = Option.map (eval env) id.Ast.equal }
      , List.map (fun (name, f) -> name, eval env f) vtable )
  | `Dyn_call (receiver, name, _, args) ->
    (match eval env receiver with
     | Object (data, _, vtable) ->
       (match List.assoc_opt name vtable with
        | Some f -> call span f (data :: eval_all env args)
        | None -> fail span "No '%s' in this object's methods." name)
     | other -> fail span "Expected an object, got %s." (type_name other))
  | `Tuple items -> Tuple (eval_all env items)
  | `Array_lit items -> Array (Array.of_list (eval_all env items))
  | `Array_new (length, fill) ->
    let length = eval env length in
    let fill = eval env fill in
    (match length with
     | Int n when n >= 0 -> Array (Array.make n fill)
     | Int _ -> fail span "An array's length must not be negative."
     | v -> fail span "Expected an int length, got %s." (type_name v))
  | `Array_get (target, index) ->
    let items = as_array target.Ast.span (eval env target) in
    let i = as_index index.Ast.span (eval env index) in
    items.(in_bounds index.Ast.span items i)
  | `Array_set (target, index, v) ->
    let items = as_array target.Ast.span (eval env target) in
    let i = as_index index.Ast.span (eval env index) in
    let value = eval env v in
    items.(in_bounds index.Ast.span items i) <- value;
    value
  | `Array_len target -> Int (Array.length (as_array target.Ast.span (eval env target)))
  | `Str_get (target, index) ->
    let scalars = as_text target.Ast.span (eval env target) in
    let i = as_index index.Ast.span (eval env index) in
    Chr scalars.(in_bounds index.Ast.span scalars i)
  | `Str_len target -> Int (Array.length (as_text target.Ast.span (eval env target)))
  | `Record_lit fields ->
    Record (nominal e.Ast.ann, List.map (fun (l, v) -> l, ref v) (eval_labeled env fields))
  | `Variant (name, fields) -> Variant (nominal e.Ast.ann, name, eval_labeled env fields)
  | `Field (target, label) ->
    (match eval env target with
     | Record (_, fields) ->
       (match List.assoc_opt label fields with
        | Some v -> !v
        | None -> fail span "No field '%s'." label)
     | v -> fail span "Cannot take a field of %s." (type_name v))
  | `Field_assign (target, label, v) ->
    let target = eval env target in
    let value = eval env v in
    (match target with
     | Record (_, fields) ->
       (match List.assoc_opt label fields with
        | Some cell ->
          cell := value;
          value
        | None -> fail span "No field '%s'." label)
     | other -> fail span "Cannot take a field of %s." (type_name other))
  | `Tuple_get (target, index) ->
    (match eval env target with
     | Tuple items -> List.nth items index
     | v -> fail span "Cannot take a field of %s." (type_name v))
and closure env name params body =
  let names = List.map (fun (p : Ast.param) -> p.Ast.name) params in
  let rec self =
    { name
    ; arity = Some (List.length names)
    ; apply =
        (fun span args ->
          let trampolined =
            match !entering with
            | Some f -> f == self
            | None -> false
          in
          entering := None;
          let frame = new_env (Some env) in
          List.iter2 (define frame) names args;
          let outer_tail = !tail in
          tail := true;
          let v =
            Fun.protect
              ~finally:(fun () -> tail := outer_tail)
              (fun () ->
                try
                  run_block frame body;
                  Unit
                with
                | Return_value (v, _) -> v)
          in
          if trampolined then v else bounce span v)
    }
  in
  Fn self

(* OCaml's argument order is unspecified, and right to left in practice. *)
and eval_all env = function
  | [] -> []
  | e :: rest ->
    let v = eval env e in
    v :: eval_all env rest

and eval_labeled env = function
  | [] -> []
  | (label, e) :: rest ->
    let v = eval env e in
    (label, v) :: eval_labeled env rest

and call span f args =
  match f with
  | Fn f ->
    let args = fitted span f args in
    entering := Some f;
    bounce span (f.apply span args)
  | v -> fail span "Cannot call %s." (type_name v)

(* A call hands evidence last to anything whose type performs an effect, and
   a function that answers its effects where it was written takes none, so
   what follows its own parameters is dropped. *)
and fitted span (f : Value.fn) args =
  match f.arity with
  | Some n when n > List.length args ->
    fail span "%s expects %d argument(s) but got %d." f.name n (List.length args)
  | Some n when n < List.length args -> List.filteri (fun i _ -> i < n) args
  | _ -> args

(* Makes the calls handed back to it, flat, rather than one level deeper each
   time. A call handed back from a bare `f(x);` leaves unit, whatever the rest
   of the chain gives back, so [discards] is carried to its end. *)
and bounce ?(discards = false) span v =
  match !pending with
  | None -> if discards then Unit else v
  | Some p ->
    pending := None;
    entering := Some p.p_fn;
    bounce ~discards:(discards || p.p_discards) span (p.p_fn.apply p.p_span p.p_args)

and run_block env body =
  (* In scope for its whole block, as the checker assumed. *)
  List.iter
    (fun (s : Ast.resolved_stmt) ->
      match s.Ast.it with
      | `Fn _ -> exec env s
      | _ -> ())
    body;
  let rec walk = function
    | [] -> ()
    | { Ast.it = `Fn _ | `Type_decl _; _ } :: rest -> walk rest
    | [ s ] -> exec_last env s
    | s :: rest ->
      not_tail (fun () -> exec env s);
      walk rest
  in
  walk body

(* A branch of an `if` in tail position is in tail position too, so a function
   ending in one whose branch is a bare call makes that call from its caller. *)
and exec_last env (s : Ast.resolved_stmt) =
  (* A builtin is applied where it stands: it never ends in a call of its own,
     and its value is what a `return` of it has to raise. *)
  let hand_back ~discards span f args ~otherwise =
    match f with
    | Fn f when (match f.arity with Some n -> n <= List.length args | None -> true) ->
      pending := Some { p_fn = f; p_args = fitted span f args; p_discards = discards; p_span = span }
    | f -> otherwise (call span f args)
  in
  let call_of env (e : Ast.resolved_expr) =
    match e.Ast.it with
    | `Call (callee, args) ->
      Some
        (fun ~discards ~otherwise ->
          let f, args = not_tail (fun () -> eval env callee, eval_all env args) in
          hand_back ~discards e.Ast.span f args ~otherwise)
    | `Dyn_call (receiver, name, _, args) ->
      Some
        (fun ~discards ~otherwise ->
          match not_tail (fun () -> eval env receiver) with
          | Object (data, _, vtable) ->
            (match List.assoc_opt name vtable with
             | Some f -> hand_back ~discards e.Ast.span f (data :: not_tail (fun () -> eval_all env args)) ~otherwise
             | None -> fail e.Ast.span "No '%s' in this object's methods." name)
          | other -> fail e.Ast.span "Expected an object, got %s." (type_name other))
    | _ -> None
  in
  match s.Ast.it with
  | `Expr e when !tail ->
    (match call_of env e with
     | Some hand -> hand ~discards:true ~otherwise:ignore
     | None -> exec env s)
  | `Return (Some e) when !tail ->
    (match call_of env e with
     | Some hand -> hand ~discards:false ~otherwise:(fun v -> raise (Return_value (v, s.Ast.span)))
     | None -> exec env s)
  | _ -> exec env s

and exec env (s : Ast.resolved_stmt) : unit =
  let span = s.Ast.span in
  match s.Ast.it with
  | `Expr e -> ignore (eval env e)
  | `Var_tuple (names, init) ->
    (match eval env init with
     | Value.Tuple items when List.length items = List.length names ->
       List.iter2 (fun name v -> define env name v) names items
     | v -> Value.fail s.Ast.span "Cannot take %s apart." (type_name v))
  | `Var_decl (name, _, init) ->
    let v =
      match init with
      | Some e -> eval env e
      | None -> Unit
    in
    define env name v
  | `Block body ->
    let scope = new_env (Some env) in
    run_block scope body
    | `Defer _ -> fail span "A 'defer' reached the interpreter unlowered."
  | `If (cond, then_branch, else_branch) ->
    if as_bool span (eval env cond)
    then exec_last env then_branch
    else (
      match else_branch with
      | Some st -> exec_last env st
      | None -> ())
  | `While (cond, body) ->
    (try
       while as_bool span (eval env cond) do
         try not_tail (fun () -> exec env body) with
         | Continue_loop -> ()
       done
     with
     | Break_loop -> ())
  | `Break -> raise Break_loop
  | `Continue -> raise Continue_loop
  (* The closure captures the table the name lands in, so recursion works
     without a separate binding step. *)
  | `Fn (name, params, _, body) -> define env name (closure env name params body)
  | `Type_decl _ -> ()
  | `Return e ->
    let v =
      match e with
      | Some x -> eval env x
      | None -> Unit
    in
    raise (Return_value (v, span))
  | `Match (scrutinee, cases) ->
    let value = eval env scrutinee in
    let bind_case (pattern : Ast.pattern) =
      match pattern, value with
      | Ast.Pat_wild, _ -> Some []
      | Ast.Pat_variant (_, name, payload), Variant (_, tag, fields)
        when String.equal name tag ->
        Some
          (List.map
             (fun (label, binding) -> binding, List.assoc label fields)
             (Ast.payload_fields payload))
      | _ -> None
    in
    let rec first = function
      | [] -> fail span "No case matched."
      | (pattern, body) :: rest ->
        (match bind_case pattern with
         | None -> first rest
         | Some bindings ->
           let scope = new_env (Some env) in
           List.iter (fun (name, v) -> define scope name v) bindings;
           run_block scope body)
    in
    first cases

(* A meta block runs from inside a builtin of the program around it, which may
   be in tail position: its own last statement is not, and a call it handed
   back would be made after the builtin returned, in place of its value. *)
let run env (program : Ast.resolved_stmt list) : (int, error) result =
  let outer_tail = !tail
  and outer_pending = !pending in
  tail := false;
  pending := None;
  try
    Fun.protect
      ~finally:(fun () ->
        tail := outer_tail;
        pending := outer_pending)
      (fun () -> run_block env program);
    Ok 0
  with
  | Exited code -> Ok code
  | Runtime_error e -> Error e
  | Return_value (_, span) -> Error { span; message = "'return' outside of a function." }
