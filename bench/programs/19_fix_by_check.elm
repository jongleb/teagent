module Main exposing (main)

import Agent exposing (..)


main : Task IoErr String
main =
    shell "sh check.sh"
        |> andThen
            (\first ->
                if first.code == 0 then
                    succeed first.out

                else
                    edit { path = "app.conf", old = "mode=loose", new = "mode=strict" }
                        |> andThen (\_ -> shell "sh check.sh")
                        |> map .out
            )
