module Main exposing (main)

import Agent exposing (..)


quoted : String -> Maybe String
quoted line =
    case String.split "\"" line of
        _ :: path :: _ ->
            Just path

        _ ->
            Nothing


main : Task IoErr (List String)
main =
    read "web/app.js"
        |> map
            (\text ->
                text
                    |> String.lines
                    |> List.filter (String.startsWith "import")
                    |> List.filterMap quoted
            )
