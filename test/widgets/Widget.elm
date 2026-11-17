module Widget exposing
    ( Live
    , Tone(..)
    , Widget
    , column
    , gauge
    , label
    , line
    , live
    , muted
    , panel
    , run
    , stat
    , status
    , table
    , text
    , toned
    )

{-| The closed catalog a widget is built from. A widget is `main = Widget.live Bus.someSource view`.
-}

import Bus exposing (State(..))
import Json.Decode as Decode
import Json.Encode as Encode


type Tone
    = Normal
    | Muted
    | Accent
    | Good
    | Attention


type Direction
    = Row
    | Column


type Widget msg
    = Stack Direction (List (Widget msg))
    | Text Tone String
    | Label String
    | Stat String String Tone
    | Gauge Float Float
    | Status State String
    | Table (List String) (List (List (Widget msg)))


type Live
    = Live String (Decode.Value -> Encode.Value)


panel : String -> List (Widget msg) -> Widget msg
panel title children =
    Stack Column (Label title :: children)


column : List (Widget msg) -> Widget msg
column children =
    Stack Column children


line : List (Widget msg) -> Widget msg
line children =
    Stack Row children


text : String -> Widget msg
text value =
    Text Normal value


muted : String -> Widget msg
muted value =
    Text Muted value


toned : Tone -> String -> Widget msg
toned tone value =
    Text tone value


label : String -> Widget msg
label value =
    Label value


stat : String -> String -> Widget msg
stat name value =
    Stat name value Normal


gauge : Int -> Int -> Widget msg
gauge value max =
    Gauge (toFloat value) (toFloat max)


status : State -> String -> Widget msg
status state note =
    Status state note


table : List String -> List (List (Widget msg)) -> Widget msg
table columns rows =
    Table columns rows


live : Bus.Source a -> (a -> Widget msg) -> Live
live source view =
    Live (Bus.name source)
        (\value ->
            case Decode.decodeValue (Bus.decoder source) value of
                Ok data ->
                    encode (view data)

                Err error ->
                    Encode.object [ ( "failed", Encode.string (Decode.errorToString error) ) ]
        )


run : Live -> { source : String, render : Decode.Value -> Encode.Value }
run (Live source render) =
    { source = source, render = render }


encode : Widget msg -> Encode.Value
encode widget =
    case widget of
        Stack direction children ->
            Encode.object [ ( "t", Encode.string "stack" ), ( "direction", Encode.string (directionName direction) ), ( "children", Encode.list encode children ) ]

        Text tone value ->
            Encode.object [ ( "t", Encode.string "text" ), ( "tone", Encode.string (toneName tone) ), ( "value", Encode.string value ) ]

        Label value ->
            Encode.object [ ( "t", Encode.string "label" ), ( "value", Encode.string value ) ]

        Stat name value tone ->
            Encode.object [ ( "t", Encode.string "stat" ), ( "label", Encode.string name ), ( "value", Encode.string value ), ( "tone", Encode.string (toneName tone) ) ]

        Gauge value max ->
            Encode.object [ ( "t", Encode.string "gauge" ), ( "value", Encode.float value ), ( "max", Encode.float max ) ]

        Status state note ->
            Encode.object [ ( "t", Encode.string "status" ), ( "state", Encode.string (stateName state) ), ( "text", Encode.string note ) ]

        Table columns rows ->
            Encode.object
                [ ( "t", Encode.string "table" )
                , ( "columns", Encode.list Encode.string columns )
                , ( "rows", Encode.list (Encode.list encode) rows )
                ]


toneName : Tone -> String
toneName tone =
    case tone of
        Normal ->
            "normal"

        Muted ->
            "muted"

        Accent ->
            "accent"

        Good ->
            "good"

        Attention ->
            "attention"


stateName : State -> String
stateName state =
    case state of
        Running ->
            "running"

        Queued ->
            "queued"

        Done ->
            "done"

        NeedsYou ->
            "needs-you"

        Failed ->
            "failed"


directionName : Direction -> String
directionName direction =
    case direction of
        Row ->
            "row"

        Column ->
            "column"
