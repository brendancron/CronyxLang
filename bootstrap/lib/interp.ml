open Value

exception Return_value of value * Ast.span

(* Caught by the loop it leaves, which is always the innermost: the checker
   refuses a `break` with anything else in between. *)
exception Break_loop
exception Continue_loop

(* Caught by the `Scope` its own `run` became, passed through any between. *)
(* Carries where it left from, so one that finds no scope can still say where. *)
exception Aborted of string * Ast.span

(* A scope is a frame on the interpreter's own stack as well as OCaml's, because
   a continuation invoked after its `run` block returned has to put back what
   entering it installed. Innermost first. *)
let active_scopes : (string * string option * Value.env) list ref = ref []

(* Tail calls. Converted code ends every function by calling the next
   continuation, so without them each step of a loop that suspends runs inside
   the last, and the stack -- and every local each step held -- grows until
   the program ends. A frame or a continuation whose body ends in a call hands
   the call to whoever called it instead of making it: [tail] says the
   statement being run is in that position, and [pending] holds the call with
   the scopes the frame had re-entered, which the caller puts back around it. *)
let tail = ref false
let tail_scopes : (string * string option * Value.env) list ref = ref []
let pending :
  (Value.fn * Value.value list * (string * string option * Value.env) list * (string * string option * Value.env) list)
  option
  ref =
  ref None

let not_tail f =
  let outer = !tail in
  tail := false;
  Fun.protect ~finally:(fun () -> tail := outer) f

(* What `discontinue` resumes a continuation with. Compared by identity, so no
   value a program builds can be mistaken for it. *)
let discontinued = Variant (None, "discontinued", [])

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
  | `Call ({ Ast.it = `Var name; _ }, [ k; back ]) when String.equal name Ast.discontinue_name ->
    ignore (call span (eval env k) [ discontinued; eval env back ]);
    Unit
  | `Call ({ Ast.it = `Var name; _ }, [ v ]) when String.equal name Ast.discontinued_name ->
    Bool (eval env v == discontinued)
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
(* OCaml's argument order is unspecified, and right to left in practice. *)
(* Outermost first, so an inner scope's catcher sits inside its outer one.

   Catching answers for the whole body rather than for the part the scope
   covered, which is enough because an abort calls the frame that follows the
   scope: what came after is reached through the catcher rather than left
   behind it. *)
and under missing k =
  match missing with
  | [] -> k ()
  | (name, exit, senv) :: inner ->
    (match under inner k with
     | v -> v
     | exception Aborted (caught, span) when String.equal caught name ->
       carry_on span senv exit;
       Unit)

and carry_on span env exit =
  match exit with
  | None -> ()
  | Some exit ->
    (match lookup env exit with
     | Some r -> not_tail (fun () -> ignore (call span !r [ Bool false ]))
     | None -> fail span "Undefined variable '%s'." exit)

(* [returns] is false for a function the CPS pass cut out of another: a
   `return` reaching it belongs to the source function it came from, so it is
   let through rather than answered here. *)
and closure ?(is_continuation = false) ?(returns = true) env name params body =
  let names = List.map (fun (p : Ast.param) -> p.Ast.name) params in
  (* A function is inside the scopes it was written in, not every scope active
     where it was made: a helper lambda made under an effect performed in a
     `run` would otherwise re-enter that `run` each time it is called, long
     after the block was left. *)
  let captured =
    if is_continuation
    then !active_scopes
    else (
      let rec within (e : Value.env) senv =
        e == senv || Option.fold ~none:false ~some:(fun p -> within p senv) e.parent
      in
      List.filter (fun (_, _, senv) -> within env senv) !active_scopes)
  in
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
          (* A live frame re-entered is still one frame. Listing it twice would
             have every continuation made from here capture it twice, and the
             list double with each resumption. *)
          active_scopes := missing @ List.filter (fun frame -> not (List.memq frame missing)) current;
          let outer_tail = !tail
          and outer_scopes = !tail_scopes in
          (* A function answers its own `return`, so a call it ends in has to
             come back through it. *)
          tail := not returns;
          tail_scopes := missing;
          Fun.protect
            ~finally:(fun () ->
              active_scopes := saved;
              tail := outer_tail;
              tail_scopes := outer_scopes)
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
    bounce span [] (f.apply span args)
  | v -> fail span "Cannot call %s." (type_name v)

(* Makes the calls handed back to it, each in the scopes the frame that handed
   it over had re-entered. Those already put back by an enclosing bounce are
   not put back again, so a loop of continuations re-entering the same scopes
   runs here, flat, rather than one level deeper each time. *)
and bounce span installed v =
  match !pending with
  | None -> v
  (* Left for the bounce outside the scope the call leaves. *)
  | Some (_, _, _, left) when List.exists (fun scope -> List.memq scope installed) left -> v
  | Some (g, args, scopes, _) ->
    pending := None;
    if List.for_all (fun scope -> List.memq scope installed) scopes
    then bounce span installed (g.apply span args)
    else (
      let saved = !active_scopes in
      active_scopes := scopes @ List.filter (fun scope -> not (List.memq scope scopes)) saved;
      Fun.protect
        ~finally:(fun () -> active_scopes := saved)
        (fun () -> under (List.rev scopes) (fun () -> bounce span scopes (g.apply span args))))

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
  let run_deferred () = not_tail (fun () -> List.iter (fun (scope, s) -> exec scope s) !deferred) in
  let rec walk = function
    | [] -> ()
    | { Ast.it = `Defer inner; _ } :: rest ->
      deferred := (env, inner) :: !deferred;
      walk rest
    | { Ast.it = `Fn _ | `Cont _ | `Frame _; _ } :: rest -> walk rest
    (* What this block defers runs when it is left, which has to be after the
       call rather than before it. *)
    | [ s ] when !deferred <> [] -> not_tail (fun () -> exec env s)
    | [ s ] -> exec_last env s
    | s :: rest ->
      not_tail (fun () -> exec env s);
      walk rest
  in
  (match walk body with
   | () -> run_deferred ()
   | exception e ->
     run_deferred ();
     raise e)

(* A branch of an `if` in tail position is in tail position too. Converted code
   ends a function with one whose `else` is a bare call to the join, and making
   that call leaves the function's frame, and every local it held, under the
   rest of the program. *)
and exec_last env (s : Ast.cps_stmt) =
  let hand_back ?(left = []) span f args =
    match f with
    | Fn f when (match f.arity with Some n -> n = List.length args | None -> true) ->
      pending := Some (f, args, List.filter (fun scope -> not (List.memq scope left)) !tail_scopes, left)
    | f -> ignore (call span f args)
  in
  match s.Ast.it with
  | `Expr { Ast.it = `Call (callee, args); span; _ } when !tail && not (discontinuing callee) ->
    let f, args = not_tail (fun () -> eval env callee, eval_all env args) in
    hand_back ~left:(leaving callee !tail_scopes) span f args
  | `Expr { Ast.it = `Dyn_call (receiver, name, _, args); span; _ } when !tail ->
    (match not_tail (fun () -> eval env receiver) with
     | Object (data, _, vtable) ->
       (match List.assoc_opt name vtable with
        | Some f -> hand_back span f (data :: not_tail (fun () -> eval_all env args))
        | None -> fail span "No '%s' in this object's methods." name)
     | other -> fail span "Expected an object, got %s." (type_name other))
  | _ -> exec env s

(* A `run` block's body ends by calling the frame its scope names, the one an
   abort calls too. That call leaves the scope
   and every scope inside it; made inside them instead, the rest of the program
   runs under each `run` it has passed, one more on every turn of a loop. *)
and leaving (callee : Ast.cps_expr) scopes =
  match callee.Ast.it with
  | `Var name ->
    let rec upto inner = function
      | [] -> []
      | ((_, Some exit, _) as scope) :: _ when String.equal exit name -> List.rev (scope :: inner)
      | scope :: rest -> upto (scope :: inner) rest
    in
    upto [] scopes
  | _ -> []

and discontinuing (callee : Ast.cps_expr) =
  match callee.Ast.it with
  | `Var name -> String.equal name Ast.discontinue_name || String.equal name Ast.discontinued_name
  | _ -> false

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
  | `Scope (scope, body, exit) ->
    let saved = !active_scopes in
    active_scopes := (scope, exit, env) :: saved;
    (match Fun.protect ~finally:(fun () -> active_scopes := saved) (fun () -> not_tail (fun () -> run_block env body))
     with
     | () -> ()
     | exception Aborted (caught, span) when String.equal caught scope -> carry_on span env exit)
  | `Abort scope -> raise (Aborted (scope, s.Ast.span))
  | `On_unwind (body, cleanup) ->
    (try not_tail (fun () -> List.iter (exec env) body) with
     | e ->
       not_tail (fun () -> List.iter (exec env) cleanup);
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

let run env (program : Ast.cps_stmt list) : (int, error) result =
  try
    run_block env program;
    Ok 0
  with
  | Exited code -> Ok code
  | Runtime_error e -> Error e
  | Return_value (_, span) -> Error { span; message = "'return' outside of a function." }
  (* The scope it named is gone: a continuation re-entered it without putting it
     back. A diagnostic rather than an escaping exception. *)
  | Aborted (_, span) ->
    Error { span; message = "An unwind found no scope left to stop at." }
