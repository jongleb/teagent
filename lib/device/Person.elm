module Person exposing (PersonErr(..), ask)

import Agent exposing (Task)


type PersonErr
    = Unanswered String


ask : String -> List String -> Task PersonErr String
ask question answers =
    Elm.Kernel.Agent.call "person.ask" { answers = answers, question = question }
