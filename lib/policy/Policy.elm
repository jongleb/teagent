module Policy exposing (Call(..), Source(..), Decision(..))


type Call
    = Read String
    | Write String
    | Edit String
    | Grep String
    | Shell String
    | Call String String


type Source
    = File String
    | Search
    | Command
    | Child
    | Driver String


type Decision
    = Allow
    | Ask String
    | Deny String
