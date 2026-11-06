module Main exposing (main)

import Agent exposing (..)


replaced : String -> Task IoErr ()
replaced path =
    read path
        |> andThen (\text -> write path (String.replace "OldLogger." "Logger." text))


main : Task IoErr (List ())
main =
    grep { pattern = "OldLogger\\.", glob = "src/**/*.ml" }
        |> andThen
            (\matches ->
                matches
                    |> List.map .path
                    |> List.unique
                    |> List.map replaced
                    |> batch
            )
