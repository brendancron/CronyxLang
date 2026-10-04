(* What `std/math` asks of the machine: each `float` native is one `libm` call,
   so a native backend's runtime implements it as that symbol. *)

(* `rint` under the default rounding mode, which OCaml does not expose. Only a
   value ending in exactly .5 differs from `round`, and halving one is exact. *)
let round_even x =
  if Float.abs (x -. Float.trunc x) = 0.5 then 2.0 *. Float.round (x /. 2.0) else Float.round x

(* IEEE 754's totalOrder: flipping the magnitude bits of a negative makes the
   bit patterns compare as signed integers in that order. *)
let total_cmp a b =
  let key x =
    let bits = Int64.bits_of_float x in
    if Int64.compare bits 0L < 0 then Int64.logxor bits Int64.max_int else bits
  in
  Int64.compare (key a) (key b)

let unary =
  [ "floor", Float.floor
  ; "ceil", Float.ceil
  ; "trunc", Float.trunc
  ; "round", Float.round
  ; "round_even", round_even
  ; "sqrt", Float.sqrt
  ; "cbrt", Float.cbrt
  ; "exp", Float.exp
  ; "exp2", Float.exp2
  ; "exp_m1", Float.expm1
  ; "ln", Float.log
  ; "log2", Float.log2
  ; "log10", Float.log10
  ; "ln_1p", Float.log1p
  ; "sin", Float.sin
  ; "cos", Float.cos
  ; "tan", Float.tan
  ; "asin", Float.asin
  ; "acos", Float.acos
  ; "atan", Float.atan
  ; "sinh", Float.sinh
  ; "cosh", Float.cosh
  ; "tanh", Float.tanh
  ; "asinh", Float.asinh
  ; "acosh", Float.acosh
  ; "atanh", Float.atanh
  ; "next_up", Float.succ
  ; "next_down", Float.pred
  ]

let binary =
  [ "hypot", Float.hypot; "atan2", Float.atan2; "copysign", Float.copy_sign; "pow", Float.pow ]

let tests =
  [ "is_nan", Float.is_nan
  ; "is_infinite", (fun x -> Float.classify_float x = FP_infinite)
  ; "is_finite", Float.is_finite
  ; "is_sign_negative", Float.sign_bit
  ]

let float_constants =
  [ "max", Float.max_float
  ; "min_positive", Float.min_float
  ; "epsilon", Float.epsilon
  ; "infinity", Float.infinity
  ; "nan", Float.nan
  ]

let wrapping = [ "add", ( + ); "sub", ( - ); "mul", ( * ) ]

let float_name name = "__float_" ^ name
let wrapping_name name = "__int_wrapping_" ^ name

let functions : (string * string * (unit -> Types.infer_ty list * Types.infer_ty)) list =
  let open Types in
  List.map (fun (name, _) -> float_name name, "", fun () -> [ IFloat ], IFloat) unary
  @ List.map (fun (name, _) -> float_name name, "", fun () -> [ IFloat; IFloat ], IFloat) binary
  @ List.map (fun (name, _) -> float_name name, "", fun () -> [ IFloat ], IBool) tests
  @ List.map (fun (name, _) -> float_name name, "", fun () -> [], IFloat) float_constants
  @ List.map (fun (name, _) -> wrapping_name name, "", fun () -> [ IInt; IInt ], IInt) wrapping
  @ [ float_name "fma", "", (fun () -> [ IFloat; IFloat; IFloat ], IFloat)
    ; float_name "total_cmp", "", (fun () -> [ IFloat; IFloat ], IInt)
    ; "__int_max", "", (fun () -> [], IInt)
    ; "__int_min", "", (fun () -> [], IInt)
    ]

let values ~native =
  let floats name arity f =
    native name arity (fun span args ->
      f
        (List.map
           (function
             | Value.Float x -> x
             | _ -> Value.fail span "%s takes floats." name)
           args))
  in
  List.map
    (fun (name, f) ->
      floats (float_name name) 1 (function
        | [ x ] -> Value.Float (f x)
        | _ -> assert false))
    unary
  @ List.map
      (fun (name, f) ->
        floats (float_name name) 2 (function
          | [ a; b ] -> Value.Float (f a b)
          | _ -> assert false))
      binary
  @ List.map
      (fun (name, f) ->
        floats (float_name name) 1 (function
          | [ x ] -> Value.Bool (f x)
          | _ -> assert false))
      tests
  @ List.map (fun (name, x) -> native (float_name name) 0 (fun _ _ -> Value.Float x)) float_constants
  @ List.map
      (fun (name, f) ->
        native (wrapping_name name) 2 (fun span args ->
          match args with
          | [ Value.Int a; Value.Int b ] -> Value.Int (f a b)
          | _ -> Value.fail span "%s takes two ints." (wrapping_name name)))
      wrapping
  @ [ floats (float_name "fma") 3 (function
        | [ a; b; c ] -> Value.Float (Float.fma a b c)
        | _ -> assert false)
    ; floats (float_name "total_cmp") 2 (function
        | [ a; b ] -> Value.Int (total_cmp a b)
        | _ -> assert false)
    ; native "__int_max" 0 (fun _ _ -> Value.Int max_int)
    ; native "__int_min" 0 (fun _ _ -> Value.Int min_int)
    ]
