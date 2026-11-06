module Main exposing (main)

import Agent exposing (..)


header : String
header =
    "(* SPDX-License-Identifier: MIT *)"


headed : String -> Task IoErr ()
headed path =
    read path
        |> andThen
            (\text ->
                if String.startsWith header text then
                    succeed ()

                else
                    write path (header ++ "\n" ++ text)
            )


main : Task IoErr (List ())
main =
    grep { pattern = "", glob = "lib/**/*.ml" }
        |> andThen
            (\lines ->
                lines
                    |> List.map .path
                    |> List.unique
                    |> List.map headed
                    |> batch
            )
