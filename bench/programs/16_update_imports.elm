module Main exposing (main)

import Agent exposing (..)


updated : String -> Task IoErr ()
updated path =
    read path
        |> andThen
            (\text ->
                write path
                    (String.replace "from utils import helper" "from common.utils import helper" text)
            )


main : Task IoErr (List ())
main =
    grep { pattern = "from utils import helper", glob = "app/**/*.py" }
        |> andThen
            (\matches ->
                matches
                    |> List.map .path
                    |> List.unique
                    |> List.map updated
                    |> batch
            )
