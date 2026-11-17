module Bus exposing
    ( Agent
    , Budget
    , Decision
    , Goal
    , Source
    , State(..)
    , Waiting(..)
    , agents
    , budget
    , decisions
    , decoder
    , goals
    , name
    )

{-| What a widget can read. Rows are denormalized: an agent already carries its goal and its state.
-}

import Json.Decode as Decode


type State
    = Running
    | Queued
    | Done
    | NeedsYou
    | Failed


type alias Agent =
    { id : String, task : String, goal : String, state : State, step : Int, doing : String, tokens : Int }


type Waiting
    = Question
    | Review


type alias Decision =
    { id : String, agent : String, title : String, waiting : Waiting }


type alias Goal =
    { id : String, text : String, agents : Int, done : Int, failed : Int, tokens : Int }


type alias Budget =
    { tokens : Int, running : Int, waiting : Int }


type Source a
    = Source String (Decode.Decoder a)


name : Source a -> String
name (Source source _) =
    source


decoder : Source a -> Decode.Decoder a
decoder (Source _ decode) =
    decode


agents : Source (List Agent)
agents =
    Source "agents"
        (Decode.list
            (Decode.map7 Agent
                (Decode.field "id" Decode.string)
                (Decode.field "task" Decode.string)
                (Decode.field "goal" Decode.string)
                (Decode.field "state" state)
                (Decode.field "step" Decode.int)
                (Decode.field "doing" Decode.string)
                (Decode.field "tokens" Decode.int)
            )
        )


decisions : Source (List Decision)
decisions =
    Source "decisions"
        (Decode.list
            (Decode.map4 Decision
                (Decode.field "id" Decode.string)
                (Decode.field "agent" Decode.string)
                (Decode.field "title" Decode.string)
                (Decode.field "waiting"
                    (Decode.string
                        |> Decode.andThen
                            (\tag ->
                                case tag of
                                    "question" ->
                                        Decode.succeed Question

                                    "review" ->
                                        Decode.succeed Review

                                    _ ->
                                        Decode.fail tag
                            )
                    )
                )
            )
        )


goals : Source (List Goal)
goals =
    Source "goals"
        (Decode.list
            (Decode.map6 Goal
                (Decode.field "id" Decode.string)
                (Decode.field "text" Decode.string)
                (Decode.field "agents" Decode.int)
                (Decode.field "done" Decode.int)
                (Decode.field "failed" Decode.int)
                (Decode.field "tokens" Decode.int)
            )
        )


budget : Source Budget
budget =
    Source "budget"
        (Decode.map3 Budget
            (Decode.field "tokens" Decode.int)
            (Decode.field "running" Decode.int)
            (Decode.field "waiting" Decode.int)
        )


state : Decode.Decoder State
state =
    Decode.string
        |> Decode.andThen
            (\tag ->
                case tag of
                    "running" ->
                        Decode.succeed Running

                    "queued" ->
                        Decode.succeed Queued

                    "done" ->
                        Decode.succeed Done

                    "needs-you" ->
                        Decode.succeed NeedsYou

                    "failed" ->
                        Decode.succeed Failed

                    _ ->
                        Decode.fail tag
            )
