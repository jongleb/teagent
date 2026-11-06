module Main exposing (main)

import Agent exposing (..)


main : Task Never String
main =
    shell "ls data/*.txt | wc -l"
        |> map (\run -> String.trim run.out)
