module Fetch exposing (Response, FetchErr(..), get)

import Agent exposing (Task)


type alias Response =
    { status : Int, body : String }


type FetchErr
    = NotGranted String
    | Unreachable String


get : String -> Task FetchErr Response
get url =
    Elm.Kernel.Agent.call "fetch.get" url
