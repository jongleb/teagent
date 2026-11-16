module Catalog exposing (search)

import Agent exposing (Task)


search : String -> Task Never String
search words =
    Elm.Kernel.Agent.call "catalog.search" words
