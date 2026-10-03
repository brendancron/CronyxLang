(* The declarations the compiler names itself, each under the name the loader
   gives it in the module that declares it. A program reaches the same
   declarations through `stdlib/prelude.cx`'s global imports, or not at all, so
   a program's own `Option` is a different name rather than a replacement. *)

(* Loaded with every program whether or not anything imports them: what the
   compiler names cannot wait for an import, and neither can the methods of a
   primitive, which are reached through the value rather than a name. *)
let modules =
  [ "core/Array"; "core/Assert"; "core/Iter"; "collections/List"; "collections/Map"; "core/Ops"
  ; "core/Option"; "core/Range"; "meta/Reflect"; "collections/Set"; "text/String"; "text/Format"
  ; "compiler/Ast"
  ]

(* As [Ast.generated] spells it, which [Types] cannot reach. *)
let name module_ declared = String.concat "#" [ "std"; Filename.basename module_; declared ]

let option = name "core/Option" "Option"
let list = name "collections/List" "List"
let iter = name "core/Iter" "Iter"
let assertion = name "core/Assert" "Assertion"
let assertion_failed = name "core/Assert" "failed"

(* Found at run time by the printer, through the name an impl's method gets. *)
let display = name "text/Format" "Display"
let debug = name "text/Format" "Debug"

let ops = name "core/Ops"
let ordering = ops "Ordering"
let eq = ops "Eq"
let partial_ord = ops "PartialOrd"
let neg = ops "Neg"
let index = ops "Index"
let index_set = ops "IndexSet"
let from_array = ops "FromArray"
let add = ops "Add"
let sub = ops "Sub"
let mul = ops "Mul"
let div = ops "Div"
let rem = ops "Rem"
let bit_and = ops "BitAnd"
let bit_or = ops "BitOr"
let bit_xor = ops "BitXor"
let shl = ops "Shl"
let shr = ops "Shr"
let bit_not = ops "BitNot"
let is_less = ops "__is_less"
let is_less_equal = ops "__is_less_equal"
let is_greater = ops "__is_greater"
let is_greater_equal = ops "__is_greater_equal"

let reflect = name "meta/Reflect"
let shape = reflect "TypeShape"
let field = reflect "TypeField"
let variant = reflect "TypeVariant"
let attr = reflect "Attr"
let attr_arg = reflect "AttrArg"

let syntax = name "compiler/Ast"
