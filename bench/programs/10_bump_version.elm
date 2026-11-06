module Main exposing (main)

import Agent exposing (..)


main : Task IoErr ()
main =
    edit
        { path = "package.json"
        , old = "\"version\": \"1.2.3\""
        , new = "\"version\": \"1.2.4\""
        }
