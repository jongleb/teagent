module Main exposing (main)

import Agent exposing (..)


type Outcome
    = Built
    | Broken { errors : List String, changed : String }


errorsIn : String -> List String
errorsIn output =
    output
        |> String.lines
        |> List.filter (\line -> String.startsWith "Error" line || String.startsWith "File \"" line)
        |> List.take 10


main : Task Never Outcome
main =
    shell "dune build 2>&1"
        |> andThen
            (\build ->
                if build.code == 0 then
                    succeed Built

                else
                    shell "git diff --stat"
                        |> map
                            (\diff ->
                                Broken
                                    { errors = errorsIn build.out
                                    , changed = String.trim diff.out
                                    }
                            )
            )
