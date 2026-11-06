module Main exposing (main)

import Agent exposing (..)


type Err
    = ReadFailed IoErr


type alias Todos =
    { path : String, count : Int }


type alias Report =
    { title : String, todos : List Todos }


main : Task Err Report
main =
    read "README.md"
        |> onError
            (\problem ->
                case problem of
                    NotFound _ ->
                        succeed ""

                    Denied path ->
                        fail (ReadFailed (Denied path))

                    Conflict path ->
                        fail (ReadFailed (Conflict path))
            )
        |> andThen
            (\readme ->
                grep { pattern = "TODO", glob = "lib/**/*.ml" }
                    |> map
                        (\matches ->
                            { title =
                                readme
                                    |> String.lines
                                    |> List.head
                                    |> Maybe.withDefault "(no README)"
                            , todos =
                                matches
                                    |> List.map .path
                                    |> List.unique
                                    |> List.map
                                        (\path ->
                                            { path = path
                                            , count =
                                                matches
                                                    |> List.filter (\found -> found.path == path)
                                                    |> List.length
                                            }
                                        )
                            }
                        )
            )
