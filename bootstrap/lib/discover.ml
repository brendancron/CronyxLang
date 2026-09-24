(* Every function a given attribute is written on.

   The walk is over surface syntax because `Desugar` is where the wrapper is
   unwound, and it is what a tool marking declarations reads instead of
   reflection: `typeof` takes a value, and a function value's type names no
   declaration to look an attribute up under. *)

let rec walk attribute found (s : Ast.stmt) =
  (match s.Ast.it with
   | `Attributed (attrs, ({ Ast.it = `Fn (name, params, _, _); _ } as inner)) ->
     if List.exists (fun (a : Ast.attr) -> String.equal a.Ast.a_name attribute) attrs
     then found := (name, params, inner.Ast.span) :: !found
   | _ -> ());
  List.iter (walk attribute found) (children s)

and children (s : Ast.stmt) =
  match s.Ast.it with
  | `Attributed (_, inner) -> [ inner ]
  | `Block body | `Fn (_, _, _, body) | `Meta body -> body
  | `Defer inner | `Gen inner -> [ inner ]
  | `If (_, t, e) -> t :: Option.to_list e
  | `While (_, body) -> [ body ]
  | `For (init, _, _, body) -> Option.to_list init @ [ body ]
  | `For_in (_, _, body) -> [ body ]
  | `Match (_, cases) -> List.concat_map snd cases
  | `Run (body, _) -> body
  | _ -> []

(* Each carries the span it was declared at, so a test that cannot be run is
   reported where it stands rather than by name alone. *)
let carrying attribute (p : Ast.program) : (string * Ast.param list * Ast.span) list =
  let found = ref [] in
  List.iter (walk attribute found) p;
  List.rev !found
