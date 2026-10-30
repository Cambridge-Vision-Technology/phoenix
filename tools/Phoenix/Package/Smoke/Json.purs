module Phoenix.Package.Smoke.Json where

import Test.Deadline.Json as Test.Deadline.Json

type Context =
  { package :: String
  , pythonEnvironment :: String
  , runtimes :: String
  , static :: String
  , curl :: String
  , node :: String
  , cucumber :: String
  , support :: String
  , feature :: String
  , processTable :: String
  , timeout :: String
  , policy :: Test.Deadline.Json.Policy
  }
