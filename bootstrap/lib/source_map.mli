(* [Span.t] is abstract so that [of_range] is the only way to make one. That is
   what makes [view] total: a span always names text this module holds, and its
   offsets have already been clamped to it, so a renderer never has to decide
   what to do when the line it was told to show is not there. *)

module File : sig
  type t

  val create : path:string -> text:string -> t
  val load : string -> (t, string) result
  val path : t -> string
  val text : t -> string
end

module Span : sig
  type t

  val of_range : File.t -> lo:int -> hi:int -> t

  (* From the start of the first to the end of the second, in one file. *)
  val join : t -> t -> t

  (* A node the compiler invented, with no source behind it. Absence is a case
     the renderer has to answer for rather than a missing field it can skip. *)
  val nowhere : t

  type located =
    { file : File.t
    ; line : int
    ; col : int
    ; line_text : string
    ; underline_from : int
    ; underline_to : int
    }

  type view =
    | Located of located
    | Nowhere_in_source

  val view : t -> view
  val path : t -> string
end
