module Main exposing (main)

import Agent exposing (..)


main : Task IoErr ()
main =
    read "docs/guide.md"
        |> andThen (\text -> write "docs/guide.md" (String.replace "recieve" "receive" text))
