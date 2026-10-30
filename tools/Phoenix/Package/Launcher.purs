module Phoenix.Package.Launcher (main) where

import Prelude

import Data.Argonaut.Decode as Data.Argonaut.Decode
import Data.Argonaut.Parser as Data.Argonaut.Parser
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Maybe as Data.Maybe
import Effect as Effect
import Effect.Exception as Effect.Exception
import Foreign.Object as Foreign.Object
import Node.Process as Node.Process
import Platform.Node.Build as Platform.Node.Build
import Platform.Node.Exec as Platform.Node.Exec

main :: Effect.Effect Unit
main = do
  arguments <- Data.Array.drop 2 <$> Node.Process.argv
  case Data.Array.uncons arguments of
    Data.Maybe.Nothing ->
      Effect.Exception.throw "Phoenix launcher configuration is missing"
    Data.Maybe.Just { head: configuration, tail: userArguments } -> do
      text <- Platform.Node.Build.readImpl configuration
      json <- Data.Either.either Effect.Exception.throw pure (Data.Argonaut.Parser.jsonParser text)
      config <-
        Data.Either.either (Effect.Exception.throw <<< show) pure (Data.Argonaut.Decode.decodeJson json)
          :: Effect.Effect { python :: String, runtimePath :: String, wasm :: String }
      inherited <- Node.Process.getEnv
      let
        path = config.runtimePath <> Data.Maybe.maybe "" (\value -> ":" <> value) (Foreign.Object.lookup "PATH" inherited)
        environment = Foreign.Object.insert "PATH" path (Foreign.Object.insert "PHOENIX_WASM_BINARY_PATH" config.wasm inherited)
      Platform.Node.Exec.execveImpl config.python ([ config.python, "-m", "phoenix.server.main", "serve" ] <> userArguments) environment
