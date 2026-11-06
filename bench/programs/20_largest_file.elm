module Main exposing (main)

import Agent exposing (..)


main : Task Never String
main =
    shell "ls -S logs | head -n 1"
        |> map (\run -> String.trim run.out)
