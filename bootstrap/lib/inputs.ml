(* What a build read. `embed` reaches files the compiler was never told about,
   and a cache whose key misses one of them is silently wrong -- which is the
   worst thing a build tool can be. Recording is here rather than at the call
   site so that a second way to read a file cannot forget to. *)

let seen : (string, unit) Hashtbl.t = Hashtbl.create 8

let reset () = Hashtbl.reset seen
let record path = Hashtbl.replace seen path ()

(* Sorted, so the same build in a different order keys the same. *)
let taken () = Hashtbl.fold (fun path () acc -> path :: acc) seen [] |> List.sort String.compare
