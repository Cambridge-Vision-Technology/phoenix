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

foreign import data SyntaxNode :: Type

foreign import filesImpl :: String -> Array String -> Array String -> Effect.Effect (Array String)
foreign import importsImpl :: String -> Effect.Effect Imports
foreign import readConfigImpl :: String -> Effect.Effect Config
foreign import parseConfigImpl :: Data.Argonaut.Core.Json -> String -> Effect.Effect ParsedConfig
foreign import resolveImpl :: String -> String -> Data.Argonaut.Core.Json -> Effect.Effect Resolution
foreign import viteConfigImpl :: String -> Data.Argonaut.Core.Json -> Effect.Effect (Control.Promise.Promise Data.Argonaut.Core.Json)
foreign import relayConfigImpl :: String -> Effect.Effect Data.Argonaut.Core.Json
foreign import aliasPatternImpl :: Data.Argonaut.Core.Json -> Effect.Effect String
foreign import sourceImpl :: String -> String -> Effect.Effect SyntaxNode
foreign import childrenImpl :: SyntaxNode -> Effect.Effect (Array SyntaxNode)
foreign import sourceTextImpl :: SyntaxNode -> Effect.Effect String
foreign import diagnosticsImpl :: SyntaxNode -> Array Data.Argonaut.Core.Json
foreign import newExpressionImpl :: SyntaxNode -> Boolean
foreign import callExpressionImpl :: SyntaxNode -> Boolean
foreign import propertyAccessImpl :: SyntaxNode -> Boolean
foreign import elementAccessImpl :: SyntaxNode -> Boolean
foreign import metaPropertyImpl :: SyntaxNode -> Boolean
foreign import identifierImpl :: SyntaxNode -> Boolean
foreign import stringLiteralImpl :: SyntaxNode -> Boolean
foreign import importDeclarationImpl :: SyntaxNode -> Boolean
foreign import importClauseNodeImpl :: SyntaxNode -> Boolean
foreign import expressionImpl :: SyntaxNode -> Data.Nullable.Nullable SyntaxNode
foreign import nameImpl :: SyntaxNode -> Data.Nullable.Nullable SyntaxNode
foreign import valueImpl :: SyntaxNode -> Data.Nullable.Nullable String
foreign import argumentsImpl :: SyntaxNode -> Data.Nullable.Nullable (Array SyntaxNode)
foreign import keywordImpl :: SyntaxNode -> Data.Nullable.Nullable Int
foreign import importKeywordImpl :: Int
foreign import importClauseImpl :: SyntaxNode -> Data.Nullable.Nullable SyntaxNode
foreign import moduleSpecifierImpl :: SyntaxNode -> Data.Nullable.Nullable SyntaxNode
foreign import typeOnlyImpl :: SyntaxNode -> Data.Nullable.Nullable Boolean
