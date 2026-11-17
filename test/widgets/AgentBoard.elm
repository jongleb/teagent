module AgentBoard exposing (main)

import Bus exposing (Agent)
import Widget exposing (Widget)


main : Widget.Live
main =
    Widget.live Bus.agents view


view : List Agent -> Widget msg
view agents =
    Widget.panel ("Агенты: " ++ String.fromInt (List.length agents))
        [ Widget.table [ "задача", "состояние", "токены" ]
            (agents |> List.sortBy .task |> List.map (\a -> [ Widget.text a.task, Widget.status a.state a.doing, Widget.text (String.fromInt a.tokens) ]))
        ]
