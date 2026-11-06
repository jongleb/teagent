module Main exposing (main)

import Agent exposing (..)


main : Task IoErr ()
main =
    edit { path = "src/settings.py", old = "MAX_RETRIES = 3", new = "MAX_RETRIES = 5" }
