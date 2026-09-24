(* Both directions are total: bytes that are not valid UTF-8 decode to U+FFFD
   rather than failing, because a string may hold anything a file or a literal
   contained. *)

let decode (bytes : string) : Uchar.t array =
  let scalars = ref [] in
  let at = ref 0 in
  while !at < String.length bytes do
    let decoded = String.get_utf_8_uchar bytes !at in
    scalars := Uchar.utf_decode_uchar decoded :: !scalars;
    at := !at + Uchar.utf_decode_length decoded
  done;
  Array.of_list (List.rev !scalars)

let encode (scalars : Uchar.t array) : string =
  let buf = Buffer.create (Array.length scalars) in
  Array.iter (Buffer.add_utf_8_uchar buf) scalars;
  Buffer.contents buf

(* Not [Stdlib.compare], which orders arrays by length first: "b" < "abc". *)
let compare (x : Uchar.t array) (y : Uchar.t array) =
  let shorter = min (Array.length x) (Array.length y) in
  let rec from i =
    if i = shorter
    then Int.compare (Array.length x) (Array.length y)
    else (
      match Uchar.compare x.(i) y.(i) with
      | 0 -> from (i + 1)
      | c -> c)
  in
  from 0
