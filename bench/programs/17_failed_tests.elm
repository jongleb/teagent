module Main exposing (main)

import Agent exposing (..)


main : Task Never (List String)
main =
    shell "sh test.sh"
        |> map
            (\run ->
                run.out
                    |> String.lines
                    |> List.filter (String.startsWith "FAIL ")
                    |> List.map (String.dropLeft 5)
            )
