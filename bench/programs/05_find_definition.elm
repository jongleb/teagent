module Main exposing (main)

import Agent exposing (..)


main : Task Never (List String)
main =
    grep { pattern = "def parse_config", glob = "src/**/*.py" }
        |> map (List.map (\found -> found.path ++ ":" ++ String.fromInt found.line))
