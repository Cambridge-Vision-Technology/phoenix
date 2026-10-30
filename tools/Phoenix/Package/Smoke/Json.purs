module Phoenix.Package.Smoke.Json where

import Test.Deadline.Json as Test.Deadline.Json

type Context =
  { package :: String
  , curl :: String
  , node :: String
  , cucumber :: String
  , support :: String
  , feature :: String
  , processTable :: String
  , timeout :: String
  , policy :: Test.Deadline.Json.Policy
  }

type Ownership = { root :: String, pid :: Int, started :: Number }
