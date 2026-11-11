type shape = Circle of float | Rect of float * float

let area ~precision shape =
  let raw = match shape with Circle r -> Float.pi *. r *. r | Rect (w, h) -> w *. h in
  Float.round (raw *. precision) /. precision

let describe shape =
  match shape with Circle _ -> "circle" | Rect _ -> "rectangle"
