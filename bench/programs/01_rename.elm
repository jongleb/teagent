module Main exposing (main)

import Agent exposing (..)


type Err
    = EditFailed IoErr


main : Task Err { out : String, code : Int }
main =
    grep { pattern = "Foo\\.bar", glob = "**/*.ml" }
        |> andThen
            (\matches ->
                matches
                    |> List.map .path
                    |> List.unique
                    |> List.map (\p -> edit { path = p, old = "Foo.bar", new = "Foo.baz" })
                    |> batch
                    |> mapErr EditFailed
            )
        |> andThen (\_ -> shell "dune test")
