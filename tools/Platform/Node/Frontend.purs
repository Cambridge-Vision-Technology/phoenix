module Platform.Node.Frontend where

import Control.Promise as Control.Promise
import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Nullable as Data.Nullable
import Effect as Effect

type Reference = { fileName :: String }
type Imports = { importedFiles :: Array Reference, referencedFiles :: Array Reference, libReferenceDirectives :: Array Reference }
type Config = { config :: Data.Argonaut.Core.Json, error :: Data.Nullable.Nullable Data.Argonaut.Core.Json }
type ParsedConfig = { fileNames :: Array String, options :: Data.Argonaut.Core.Json, errors :: Array Data.Argonaut.Core.Json }
type Resolution = { resolvedModule :: Data.Nullable.Nullable { resolvedFileName :: String } }

foreign import filesImpl :: String -> Array String -> Array String -> Effect.Effect (Array String)
foreign import importsImpl :: String -> Effect.Effect Imports
foreign import readConfigImpl :: String -> Effect.Effect Config
foreign import parseConfigImpl :: Data.Argonaut.Core.Json -> String -> Effect.Effect ParsedConfig
foreign import resolveImpl :: String -> String -> Data.Argonaut.Core.Json -> Effect.Effect Resolution
foreign import viteConfigImpl :: String -> Data.Argonaut.Core.Json -> Effect.Effect (Control.Promise.Promise Data.Argonaut.Core.Json)
foreign import relayConfigImpl :: String -> Effect.Effect Data.Argonaut.Core.Json
foreign import aliasPatternImpl :: Data.Argonaut.Core.Json -> Effect.Effect String
