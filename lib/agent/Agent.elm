module Agent exposing
    ( Task, IoErr(..), Match, Mount(..), Change, Child
    , read
    , write
    , edit
    , grep
    , shell
    , hole
    , spawn
    , merge
    , succeed, fail, andThen, map, mapErr, onError, batch, fromResult
    )


type Task e a
    = Task


type IoErr
    = NotFound String
    | Denied String
    | Conflict String


type alias Match =
    { path : String, line : Int, text : String }


type Mount
    = Hidden String
    | Readonly String
    | Scratch String


type alias Change =
    { path : String, base : Maybe String, content : Maybe String }


type alias Child a =
    { value : a, changes : List Change }


read : String -> Task IoErr String
read =
    Elm.Kernel.Agent.read


write : String -> String -> Task IoErr ()
write =
    Elm.Kernel.Agent.write


edit : { path : String, old : String, new : String } -> Task IoErr ()
edit =
    Elm.Kernel.Agent.edit


grep : { pattern : String, glob : String } -> Task e (List Match)
grep =
    Elm.Kernel.Agent.grep


shell : String -> Task e { out : String, code : Int }
shell =
    Elm.Kernel.Agent.shell


hole : String -> Task e a
hole =
    Elm.Kernel.Agent.hole


spawn : List Mount -> Task e a -> Task e (Child a)
spawn mounts task =
    Elm.Kernel.Agent.enter mounts
        |> andThen (\_ -> task)
        |> onError (\problem -> Elm.Kernel.Agent.leave () |> andThen (\_ -> fail problem))
        |> andThen
            (\value ->
                Elm.Kernel.Agent.leave ()
                    |> map (\changes -> { value = value, changes = changes })
            )


merge : Child a -> Task (List Change) a
merge child =
    Elm.Kernel.Agent.merge child.changes
        |> map (\_ -> child.value)


succeed : a -> Task e a
succeed =
    Elm.Kernel.Agent.succeed


fail : e -> Task e a
fail =
    Elm.Kernel.Agent.fail


andThen : (a -> Task e b) -> Task e a -> Task e b
andThen =
    Elm.Kernel.Agent.andThen


map : (a -> b) -> Task e a -> Task e b
map =
    Elm.Kernel.Agent.map


mapErr : (e -> f) -> Task e a -> Task f a
mapErr =
    Elm.Kernel.Agent.mapErr


onError : (e -> Task f a) -> Task e a -> Task f a
onError =
    Elm.Kernel.Agent.onError


batch : List (Task e a) -> Task e (List a)
batch =
    Elm.Kernel.Agent.batch


fromResult : Result e a -> Task e a
fromResult result =
    case result of
        Ok value ->
            succeed value

        Err problem ->
            fail problem
