open Value

exception Return_value of value * Ast.span

(* Caught by the `Scope` its own `run` became, passed through any between. *)
(* Carries where it left from, so one that finds no scope can still say where. *)
exception Aborted of string * Ast.span

(* A scope is a frame on the interpreter's own stack as well as OCaml's, because
   a continuation invoked after its `run` block returned has to put back what
   entering it installed. Innermost first. *)
let active_scopes : (string * Ast.cps_stmt list * Value.env) list ref = ref []

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
  | Ast.Equal, _, _ -> Bool (values_equal a b)
  | Ast.Not_equal, _, _ -> Bool (not (values_equal a b))
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

let rec eval env (e : Ast.cps_expr) : value =
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
  | `Object (data, vtable) ->
    Object (eval env data, List.map (fun (name, f) -> name, eval env f) vtable)
  | `Dyn_call (receiver, name, _, args) ->
    (match eval env receiver with
     | Object (data, vtable) ->
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
    Record (List.map (fun (l, v) -> l, ref v) (eval_labeled env fields))
  | `Variant (name, fields) -> Variant (name, eval_labeled env fields)
  | `Field (target, label) ->
    (match eval env target with
     | Record fields ->
       (match List.assoc_opt label fields with
        | Some v -> !v
        | None -> fail span "No field '%s'." label)
     | v -> fail span "Cannot take a field of %s." (type_name v))
  | `Field_assign (target, label, v) ->
    let target = eval env target in
    let value = eval env v in
    (match target with
     | Record fields ->
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
(* OCaml's argument order is unspecified, and right to left in practice. *)
(* Outermost first, so an inner scope's catcher sits inside its outer one.

   Catching answers for the whole body rather than for the part the scope
   covered, which is enough because a scope's [on_abort] calls the continuation
   that follows it: what came after is reached through the catcher rather than
   left behind it. *)
and under missing k =
  match missing with
  | [] -> k ()
  | (name, on_abort, senv) :: inner ->
    (match under inner k with
     | v -> v
     | exception Aborted (caught, _) when String.equal caught name ->
       List.iter (exec senv) on_abort;
       Unit)

(* [returns] is false for a function the CPS pass cut out of another: a
   `return` reaching it belongs to the source function it came from, so it is
   let through rather than answered here. *)
and closure ?(is_continuation = false) ?(returns = true) env name params body =
  let names = List.map (fun (p : Ast.param) -> p.Ast.name) params in
  let captured = !active_scopes in
  Fn
    { name
    ; arity = Some (List.length names)
    ; apply =
        (fun _ args ->
          let frame = new_env (Some env) in
          List.iter2 (define frame) names args;
          (* What it was made under and is no longer inside. Re-entering only
             those leaves an ordinary call, made where it was written, alone. *)
          let current = !active_scopes in
          (* A continuation is the rest of a computation that was inside those
             frames, so it is inside them again even where they are still live:
             the arm resuming it is outside them, and an abort must land in the
             continuation rather than unwind through the arm. Any other closure
             re-enters only what is gone. *)
          let missing =
            if is_continuation
            then captured
            else
              List.filter
                (fun (n, _, _) ->
                  not (List.exists (fun (m, _, _) -> String.equal m n) current))
                captured
          in
          let saved = current in
          active_scopes := missing @ current;
          Fun.protect
            ~finally:(fun () -> active_scopes := saved)
            (fun () ->
              under
                (List.rev missing)
                (fun () ->
                  try
                    run_block frame body;
                    Unit
                  with
                  | Return_value (v, _) when returns -> v)))
    }

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
    (match f.arity with
     | Some n when n <> List.length args ->
       fail span "%s expects %d argument(s) but got %d." f.name n (List.length args)
     | _ -> ());
    f.apply span args
  | v -> fail span "Cannot call %s." (type_name v)

(* Deferred statements run when the block is left, however it is left, and in
   reverse. *)
and run_block env body =
  (* In scope for its whole block, as the checker assumed. *)
  List.iter
    (fun (s : Ast.cps_stmt) ->
      match s.Ast.it with
      | `Fn _ | `Cont _ | `Frame _ -> exec env s
      | _ -> ())
    body;
  let deferred = ref [] in
  let run_deferred () = List.iter (fun (scope, s) -> exec scope s) !deferred in
  let rec walk = function
    | [] -> ()
    | { Ast.it = `Defer inner; _ } :: rest ->
      deferred := (env, inner) :: !deferred;
      walk rest
    | { Ast.it = `Fn _ | `Cont _ | `Frame _; _ } :: rest -> walk rest
    | s :: rest ->
      exec env s;
      walk rest
  in
  (match walk body with
   | () -> run_deferred ()
   | exception e ->
     run_deferred ();
     raise e)

and exec env (s : Ast.cps_stmt) : unit =
  let span = s.Ast.span in
  match s.Ast.it with
  | `Expr e -> ignore (eval env e)
  | `Var_tuple (names, init) ->
    (match eval env init with
     | Value.Tuple items when List.length items = List.length names ->
       List.iter2 (fun name v -> define env name v) names items
     | v -> Value.fail s.Ast.span "Cannot take %s apart." (type_name v))
  (* Nothing catches this in between: a function's own handler is for
     `return`. *)
  | `Scope (scope, body, on_abort) ->
    let saved = !active_scopes in
    active_scopes := (scope, on_abort, env) :: saved;
    (match Fun.protect ~finally:(fun () -> active_scopes := saved) (fun () ->
             List.iter (exec env) body)
     with
     | () -> ()
     | exception Aborted (caught, _) when String.equal caught scope ->
       List.iter (exec env) on_abort)
  | `Abort scope -> raise (Aborted (scope, s.Ast.span))
  | `On_unwind (body, cleanup) ->
    (try List.iter (exec env) body with
     | e ->
       List.iter (exec env) cleanup;
       raise e)
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
    | `Defer _ -> ()
  | `If (cond, then_branch, else_branch) ->
    if as_bool span (eval env cond)
    then exec env then_branch
    else (
      match else_branch with
      | Some st -> exec env st
      | None -> ())
  | `While (cond, body) ->
    while as_bool span (eval env cond) do
      exec env body
    done
  (* The closure captures the table the name lands in, so recursion works
     without a separate binding step. *)
  | `Fn (name, params, _, body) -> define env name (closure env name params body)
  | `Cont (name, params, body) ->
    define env name (closure ~is_continuation:true ~returns:false env name params body)
  | `Frame (name, params, body) ->
    define env name (closure ~returns:false env name params body)
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
      | Ast.Pat_variant (_, name, payload), Variant (tag, fields)
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

let run env (program : Ast.cps_stmt list) : (unit, error) result =
  try
    run_block env program;
    Ok ()
  with
  | Runtime_error e -> Error e
  | Return_value (_, span) -> Error { span; message = "'return' outside of a function." }
  (* The scope it named is gone: a continuation re-entered it without putting it
     back. A diagnostic rather than an escaping exception. *)
  | Aborted (_, span) ->
    Error { span; message = "An unwind found no scope left to stop at." }
