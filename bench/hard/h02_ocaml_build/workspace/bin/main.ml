let () =
  let shapes = [ Shapes.Circle 1.0; Shapes.Rect (2.0, 3.0) ] in
  List.iter
    (fun shape ->
      Printf.printf "%s: %.2f\n" (Shapes.describe shape) (Shapes.area shape))
    shapes
