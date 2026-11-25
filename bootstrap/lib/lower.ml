(* Loops rewritten into the `while` they mean. Each builder is open in the tree
   it builds, so the parser's surface statements and the checker's take the
   same code. *)

open Ast

let counter = ref 0

let fresh prefix =
  incr counter;
  generated [ prefix; string_of_int !counter ]

(* The element is bound straight to the name: an intermediate variable would be
   generalized before `[]` has said what it holds. One name binds the value;
   several take it apart by position, and the arity is written down, so this
   needs no type. *)
let bound span (names : binder) element =
  let decl n init = { it = `Var_decl (n, None, Some init); span; ann = () } in
  match names with
  | [ only ] -> [ decl only element ]
  | names ->
    let whole = fresh "tuple" in
    decl whole element
    :: List.mapi
         (fun index n -> decl n { it = `Tuple_get ({ it = `Var whole; span; ann = () }, index); span; ann = () })
         names

let rec holds_continue s =
  match s.it with
  | `Continue -> true
  | `Block body -> List.exists holds_continue body
  | `If (_, t, e) -> holds_continue t || Option.fold ~none:false ~some:holds_continue e
  | `Match (_, cases) -> List.exists (fun (_, body) -> List.exists holds_continue body) cases
  | _ -> false

(* Printed and parsed again, so it has to scan, and it is the same for every
   loop because the reparse meets a `while` and makes none. A loop nested in
   the body declares its own in an inner block, which is read only before the
   body runs. *)
let first = "__for_first"

(* A step at the end of the body is skipped by a `continue` in it, so a loop
   holding one steps at the top of every iteration but the first instead. *)
let looped span cond body step =
  let node it = { it; span; ann = () } in
  match step with
  | None -> node (`While (cond, body))
  | Some step when not (holds_continue body) ->
    node (`While (cond, { body with it = `Block [ body; { it = `Expr step; span = step.span; ann = () } ] }))
  | Some step ->
    node
      (`Block
        [ node (`Var_decl (first, None, Some (node (`Bool true))))
        ; node
            (`While
              ( node (`Bool true)
              , node
                  (`Block
                    [ node
                        (`If
                          ( node (`Var first)
                          , node (`Expr (node (`Assign (first, node (`Bool false)))))
                          , Some (node (`Expr step)) ))
                    ; node (`If (node (`Unop (Not, cond)), node `Break, None))
                    ; body
                    ]) ))
        ])

(* for (init; cond; step) body  ⇒  { init; while (cond) { body; step; } } *)
let c_for span init cond step body : stmt =
  let cond =
    match cond with
    | None -> at span (`Bool true)
    | Some c -> c
  in
  let loop = looped span cond body step in
  at
    span
    (`Block
      (match init with
       | Some i -> [ i; loop ]
       | None -> [ loop ]))

(* indexed: { var i = 0; while (i < seq.len()) { var x = seq[i]; body; i = i + 1; } }
   `len` and `[]` are ordinary calls, resolved for whatever the sequence is. *)
let indexed span (names : binder) seq body =
  let node it = { it; span; ann = () } in
  let index = fresh "i" in
  let step = node (`Assign (index, node (`Binop (Add, node (`Var index), node (`Int 1))))) in
  let inner = node (`Block (bound span names (node (`Index (node (`Var seq), node (`Var index)))) @ [ body ])) in
  [ node (`Var_decl (index, None, Some (node (`Int 0))))
  ; looped
      span
      (node (`Binop (Less, node (`Var index), node (`Method_call (node (`Var seq), "len", "len", [], None)))))
      inner
      (Some step)
  ]

(* pulled: { defer seq.close(); var more = true;
             while (more) { match seq.next() { Some(x) => { body } None => { more = false; } } } }
   A bare `next` closure is called as `seq()` and has nothing to close. The
   `defer` is what lets go of a producer a `break` or a `return` left early. *)
let pulled span (names : binder) seq ~closes body =
  let node it = { it; span; ann = () } in
  let more = fresh "more"
  and element = fresh "item" in
  let asked =
    if closes
    then node (`Method_call (node (`Var seq), "next", "next", [], None))
    else node (`Call (node (`Var seq), []))
  in
  let closing =
    if closes
    then [ node (`Defer (node (`Expr (node (`Method_call (node (`Var seq), "close", "close", [], None)))))) ]
    else []
  in
  closing
  @ [ node (`Var_decl (more, None, Some (node (`Bool true))))
    ; node
        (`While
          ( node (`Var more)
          , node
              (`Match
                ( asked
                , [ ( Pat_variant (Core.option, "Some", P_tuple [ element ])
                    , bound span names (node (`Var element)) @ [ body ] )
                  ; ( Pat_variant (Core.option, "None", P_none)
                    , [ node (`Expr (node (`Assign (more, node (`Bool false))))) ] )
                  ] )) ))
    ]
