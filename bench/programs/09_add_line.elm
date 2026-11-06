module Main exposing (main)

import Agent exposing (..)


main : Task IoErr ()
main =
    read "deploy/exclude.txt"
        |> andThen (\text -> write "deploy/exclude.txt" (text ++ "node_modules/\n"))
