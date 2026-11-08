module Fetch exposing (Response, FetchErr(..), get, post)

import Agent exposing (Task)


type alias Response =
    { status : Int, body : String }


type FetchErr
    = NotGranted String
    | Unreachable String
    | Declined String


get : String -> Task FetchErr Response
get url =
    Elm.Kernel.Agent.call "fetch.get" url


post : String -> String -> Task FetchErr Response
post url body =
    Elm.Kernel.Agent.call "fetch.post" { url = url, body = body }
