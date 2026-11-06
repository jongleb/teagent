module Main exposing (main)

import Agent exposing (..)


main : Task IoErr ()
main =
    read "lib/math.ml"
        |> andThen
            (\text ->
                text
                    |> String.replace "let calc " "let double "
                    |> String.replace "calc (" "double ("
                    |> String.replace "(calc " "(double "
                    |> write "lib/math.ml"
            )
