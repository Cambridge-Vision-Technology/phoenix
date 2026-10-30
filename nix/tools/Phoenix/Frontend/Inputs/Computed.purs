module Phoenix.Frontend.Inputs.Computed (Site(..), Inspector, inspector) where

import Prelude

import Data.Array as Data.Array
import Data.Foldable as Data.Foldable
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Data.String as Data.String
import Data.String.Utils as Data.String.Utils
import Data.Traversable as Data.Traversable
import Effect as Effect
import Effect.Exception as Effect.Exception
import Effect.Ref as Effect.Ref
import Foreign.Object as Foreign.Object
import Platform.Node.Frontend as Platform.Node.Frontend

data Site = ImportedWorkerURL { expression :: String, request :: String } | LiteralURL { expression :: String, request :: String }
type Inspector = { check :: String -> String -> Effect.Effect (Array Site), statistics :: Effect.Effect { freshFiles :: Int, reusedFiles :: Int } }
type Import = { binding :: String, request :: String }

name :: Platform.Node.Frontend.SyntaxNode -> Data.Maybe.Maybe String
name node = Data.Nullable.toMaybe (Platform.Node.Frontend.nameImpl node) >>= Data.Nullable.toMaybe <<< Platform.Node.Frontend.valueImpl

meta :: Platform.Node.Frontend.SyntaxNode -> Boolean
meta node = Platform.Node.Frontend.metaPropertyImpl node
  && Data.Nullable.toMaybe (Platform.Node.Frontend.keywordImpl node) == Data.Maybe.Just Platform.Node.Frontend.importKeywordImpl
  && name node == Data.Maybe.Just "meta"

metaUrl :: Platform.Node.Frontend.SyntaxNode -> Boolean
metaUrl node = Platform.Node.Frontend.propertyAccessImpl node && name node == Data.Maybe.Just "url"
  && Data.Maybe.maybe false meta (Data.Nullable.toMaybe (Platform.Node.Frontend.expressionImpl node))

glob :: Platform.Node.Frontend.SyntaxNode -> Boolean
glob node = Platform.Node.Frontend.propertyAccessImpl node && name node == Data.Maybe.Just "glob"
  && Data.Maybe.maybe false meta (Data.Nullable.toMaybe (Platform.Node.Frontend.expressionImpl node))

nodes :: Platform.Node.Frontend.SyntaxNode -> Effect.Effect (Array Platform.Node.Frontend.SyntaxNode)
nodes node = do
  children <- Platform.Node.Frontend.childrenImpl node
  descendants <- Data.Array.concat <$> Data.Traversable.traverse nodes children
  pure ([ node ] <> descendants)

unsupported :: forall a. String -> String -> Platform.Node.Frontend.SyntaxNode -> Effect.Effect a
unsupported path form node = do
  expression <- Platform.Node.Frontend.sourceTextImpl node
  Effect.Exception.throw ("Unsupported Vite computed asset " <> form <> " in " <> path <> ": " <> expression)

inspect :: String -> String -> Effect.Effect (Array Site)
inspect path text = do
  source <- Platform.Node.Frontend.sourceImpl path text
  unless (Data.Array.null (Platform.Node.Frontend.diagnosticsImpl source)) (Effect.Exception.throw ("Cannot parse Vite computed-asset source: " <> path))
  syntax <- nodes source
  let
    imports :: Array Import
    imports = Data.Array.mapMaybe
      ( \node ->
          if Platform.Node.Frontend.importDeclarationImpl node then do
            clause <- Data.Nullable.toMaybe (Platform.Node.Frontend.importClauseImpl node)
            if Data.Nullable.toMaybe (Platform.Node.Frontend.typeOnlyImpl clause) == Data.Maybe.Just true then Data.Maybe.Nothing
            else do
              binding <- name clause
              specifier <- Data.Nullable.toMaybe (Platform.Node.Frontend.moduleSpecifierImpl node)
              request <- Data.Nullable.toMaybe (Platform.Node.Frontend.valueImpl specifier)
              pure { binding, request }
          else Data.Maybe.Nothing
      )
      syntax
    shadowed binding = Data.Foldable.any (\node -> name node == Data.Maybe.Just binding && not (Platform.Node.Frontend.importClauseNodeImpl node)) syntax
  sites <- Data.Traversable.traverse
    ( \node -> do
        let
          expression = Data.Nullable.toMaybe (Platform.Node.Frontend.expressionImpl node)
          arguments = Data.Maybe.fromMaybe [] (Data.Nullable.toMaybe (Platform.Node.Frontend.argumentsImpl node))
          urlConstructor = Platform.Node.Frontend.newExpressionImpl node && Data.Maybe.maybe false (\callee -> Platform.Node.Frontend.identifierImpl callee && Data.Nullable.toMaybe (Platform.Node.Frontend.valueImpl callee) == Data.Maybe.Just "URL") expression
        when (Platform.Node.Frontend.callExpressionImpl node && Data.Maybe.maybe false glob expression) (unsupported path "import.meta.glob" node)
        when (glob node) (unsupported path "import.meta.glob reference" node)
        when (Platform.Node.Frontend.elementAccessImpl node && Data.Maybe.maybe false meta expression) (unsupported path "computed import.meta access" node)
        if urlConstructor then do
          argumentNodes <- Data.Array.concat <$> Data.Traversable.traverse nodes arguments
          if Data.Foldable.any meta argumentNodes then case arguments of
            [ argument, base ] -> do
              let
                binding = if Platform.Node.Frontend.identifierImpl argument then Data.Nullable.toMaybe (Platform.Node.Frontend.valueImpl argument) else Data.Maybe.Nothing
                imported = binding >>= \value -> case Data.Array.filter (_.binding >>> (_ == value)) imports of
                  [ found ] | not (shadowed value) -> Data.Maybe.Just found
                  _ -> Data.Maybe.Nothing
              case Data.Nullable.toMaybe (Platform.Node.Frontend.valueImpl argument) of
                Data.Maybe.Just request | Platform.Node.Frontend.stringLiteralImpl argument && metaUrl base && Data.String.Utils.startsWith "." request && not (Data.String.contains (Data.String.Pattern "?") request || Data.String.contains (Data.String.Pattern "#") request) -> do
                  rendered <- Platform.Node.Frontend.sourceTextImpl node
                  pure [ LiteralURL { expression: rendered, request } ]
                _ -> case imported of
                  Data.Maybe.Just found | metaUrl base && Data.String.Utils.startsWith "." found.request && Data.String.Utils.endsWith "?worker&url" found.request -> do
                    rendered <- Platform.Node.Frontend.sourceTextImpl node
                    pure [ ImportedWorkerURL { expression: rendered, request: found.request } ]
                  _ ->
                    unsupported path "new URL" node
            _ ->
              unsupported path "new URL" node
          else pure []
        else pure []
    )
    syntax
  pure (Data.Array.concat sites)

inspector :: Effect.Effect Inspector
inspector = do
  cache <- Effect.Ref.new Foreign.Object.empty
  statistics <- Effect.Ref.new { freshFiles: 0, reusedFiles: 0 }
  let
    check path text =
      if not (Data.Foldable.any (\extension -> Data.String.Utils.endsWith extension path) [ ".ts", ".tsx", ".js", ".jsx", ".mts", ".cts", ".mjs", ".cjs" ]) then pure []
      else do
        previous <- Foreign.Object.lookup path <$> Effect.Ref.read cache
        case previous of
          Data.Maybe.Just value | value.text == text -> do
            Effect.Ref.modify_ (\counts -> counts { reusedFiles = counts.reusedFiles + 1 }) statistics
            pure value.sites
          _ -> do
            sites <- inspect path text
            Effect.Ref.modify_ (Foreign.Object.insert path { text, sites }) cache
            Effect.Ref.modify_ (\counts -> counts { freshFiles = counts.freshFiles + 1 }) statistics
            pure sites
  pure { check, statistics: Effect.Ref.read statistics }
