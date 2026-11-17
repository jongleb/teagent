module Live exposing (Program, program, perform, attempt, listen)

import Agent exposing (Task)
import Json.Decode


type Program model msg view
    = Program
        { init : ( model, Cmd msg )
        , update : msg -> model -> ( model, Cmd msg )
        , view : model -> view
        , subscriptions : model -> Sub msg
        }


program :
    { init : ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , view : model -> view
    , subscriptions : model -> Sub msg
    }
    -> Program model msg view
program =
    Program


perform : (a -> msg) -> Task Never a -> Cmd msg
perform =
    Elm.Kernel.Live.perform


attempt : (Result e a -> msg) -> Task e a -> Cmd msg
attempt toMsg task =
    task
        |> Agent.map (\value -> toMsg (Ok value))
        |> Agent.onError (\problem -> Agent.succeed (toMsg (Err problem)))
        |> perform identity


listen : String -> (Json.Decode.Value -> msg) -> Sub msg
listen =
    Elm.Kernel.Live.listen
