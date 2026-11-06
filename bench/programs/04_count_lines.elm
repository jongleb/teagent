module Main exposing (main)

import Agent exposing (..)


main : Task IoErr Int
main =
    read "src/main.py"
        |> map
            (\text ->
                text
                    |> String.lines
                    |> List.filter (\line -> line /= "")
                    |> List.length
            )
