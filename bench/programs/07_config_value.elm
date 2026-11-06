module Main exposing (main)

import Agent exposing (..)


main : Task IoErr (Maybe String)
main =
    read "config.toml"
        |> map
            (\text ->
                text
                    |> String.lines
                    |> List.filter (String.startsWith "port")
                    |> List.head
                    |> Maybe.andThen
                        (\line ->
                            case String.split "=" line of
                                _ :: value :: _ ->
                                    Just (String.trim value)

                                _ ->
                                    Nothing
                        )
            )
