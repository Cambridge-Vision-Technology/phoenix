module Phoenix.Package.Smoke.Json where

import Foreign.Object as Foreign.Object
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

type Ownership =
  { root :: String
  , pid :: Int
  , port :: Int
  , grpcPort :: Int
  , arguments :: Array String
  , environment :: Foreign.Object.Object String
  , stallCucumber :: Boolean
  }
