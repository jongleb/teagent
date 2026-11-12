module Model exposing (ModelErr(..), judge)

import Agent exposing (Task)


type ModelErr
    = Unclear String
    | Unreachable String
    | Declined String


judge : String -> List String -> Task ModelErr String
judge question answers =
    Elm.Kernel.Agent.call "model.judge" { answers = answers, question = question }
