module Counter exposing (main)

import Agent
import Json.Decode as Decode
import Live


type Msg
    = Clicked
    | Typed String
    | Loaded Int
    | Heard Int


type alias Model =
    { count : Int, text : String }


type View
    = Shown Int String
    | Button { label : String, onPress : Msg }
    | Field (String -> Msg)


main : Live.Program Model Msg (List View)
main =
    Live.program
        { init = ( { count = 0, text = "" }, Live.perform Loaded (Agent.succeed 40) )
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Clicked ->
            ( { model | count = model.count + 1 }, Cmd.none )

        Typed text ->
            ( { model | text = text }, Cmd.batch [ Cmd.map identity (Live.perform Loaded (Agent.succeed 1)) ] )

        Loaded more ->
            ( { model | count = model.count + more }, Cmd.none )

        Heard count ->
            ( { model | count = count }, Cmd.none )


view : Model -> List View
view model =
    [ Shown model.count model.text, Button { label = "+", onPress = Clicked }, Field Typed ]


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.count > 1000 then
        Sub.none

    else
        Sub.map identity
            (Live.listen "agents"
                (\value ->
                    Heard (Result.withDefault 0 (Decode.decodeValue (Decode.map List.length (Decode.list Decode.value)) value))
                )
            )
