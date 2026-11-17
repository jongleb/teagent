module Harness exposing (render, source)

import AgentBoard
import Json.Decode
import Json.Encode
import Widget


source : () -> String
source _ =
    (Widget.run AgentBoard.main).source


render : Json.Decode.Value -> Json.Encode.Value
render value =
    (Widget.run AgentBoard.main).render value
