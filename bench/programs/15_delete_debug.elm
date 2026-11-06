module Main exposing (main)

import Agent exposing (..)


cleaned : String -> Task IoErr ()
cleaned path =
    read path
        |> andThen
            (\text ->
                text
                    |> String.lines
                    |> List.filter (\line -> not (String.contains "print_debug" line))
                    |> String.join "\n"
                    |> write path
            )


main : Task IoErr (List ())
main =
    grep { pattern = "print_debug", glob = "src/**/*.ml" }
        |> andThen
            (\matches ->
                matches
                    |> List.map .path
                    |> List.unique
                    |> List.map cleaned
                    |> batch
            )
