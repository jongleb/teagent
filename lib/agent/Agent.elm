module Agent exposing
    ( Task, IoErr(..), Match
    , read, write, edit, grep, shell
    , succeed, fail, andThen, map, mapErr, onError, batch
    )


type Task e a
    = Task


type IoErr
    = NotFound String
    | Denied String
    | Conflict String


type alias Match =
    { path : String, line : Int, text : String }


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
