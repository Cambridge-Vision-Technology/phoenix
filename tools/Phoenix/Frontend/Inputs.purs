module Phoenix.Frontend.Inputs (main) where

import Prelude

import Build.Json as Build.Json
import Control.Promise as Control.Promise
import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Decode as Data.Argonaut.Decode
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Argonaut.Parser as Data.Argonaut.Parser
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Data.Set as Data.Set
import Data.String as Data.String
import Data.String.Utils as Data.String.Utils
import Data.Traversable as Data.Traversable
import Data.Tuple as Data.Tuple
import Effect as Effect
import Effect.Aff as Effect.Aff
import Effect.Class as Effect.Class
import Effect.Exception as Effect.Exception
import Effect.Ref as Effect.Ref
import Foreign.Object as Foreign.Object
import Node.Path as Node.Path
import Node.Process as Node.Process
import Phoenix.Frontend.Inputs.Json as Phoenix.Frontend.Inputs.Json
import Platform.Node.Build as Platform.Node.Build
import Platform.Node.Frontend as Platform.Node.Frontend
import Platform.Node.Inventory as Platform.Node.Inventory

require :: Boolean -> String -> Effect.Effect Unit
require condition message = unless condition (Effect.Exception.throw message)

field :: forall a. Data.Argonaut.Decode.DecodeJson a => String -> Data.Argonaut.Core.Json -> Effect.Effect a
field name value = do
  object <- Data.Either.either (Effect.Exception.throw <<< show) pure (Data.Argonaut.Decode.decodeJson value) :: Effect.Effect (Foreign.Object.Object Data.Argonaut.Core.Json)
  Data.Either.either (Effect.Exception.throw <<< show) pure (Data.Argonaut.Decode.getField object name)

canonical :: Array String -> Array String
canonical = Data.Array.sort <<< Data.Array.nub

relative :: String -> String -> Effect.Effect String
relative root path = do
  let
    result = Node.Path.relative root path
  require (result /= "" && not (Data.String.Utils.startsWith ".." result) && not (Node.Path.isAbsolute result)) ("Input outside frontend source root: " <> path)
  pure result

nonProduct :: String -> Boolean
nonProduct path = Data.Foldable.any (\segment -> Data.Array.elem segment [ "__tests__", "__mocks__", "fixtures", "__fixtures__", "node_modules" ]) (Data.String.split (Data.String.Pattern "/") path)
  || Data.Foldable.any (\part -> Data.String.contains (Data.String.Pattern part) path) [ ".test.", ".spec.", ".stories." ]

generated :: Phoenix.Frontend.Inputs.Json.Assets -> String -> Boolean
generated assets path = Data.String.Utils.endsWith ".graphql.ts" path || Data.Array.elem path (map _.output assets.generators)

workspaceClosure :: String -> Effect.Effect (Array Phoenix.Frontend.Inputs.Json.Workspace)
workspaceClosure executable = do
  let
    arguments = [ "--filter", "phoenix-ui...", "list", "--depth", "-1", "--json" ]
  result <- Platform.Node.Inventory.graphImpl executable arguments { encoding: "utf8", timeout: 20000, maxBuffer: 33554432 }
  require (Data.Nullable.toMaybe result.status == Data.Maybe.Just 0 && Data.Maybe.isNothing (Data.Nullable.toMaybe result.error)) ("Frontend graph command failed: " <> show arguments <> " " <> show result.stderr)
  text <- Data.Maybe.maybe (Effect.Exception.throw "Graph command returned no JSON") pure (Data.Nullable.toMaybe result.stdout)
  json <- Data.Either.either Effect.Exception.throw pure (Data.Argonaut.Parser.jsonParser text)
  workspaces <- Data.Either.either (Effect.Exception.throw <<< show) pure (Data.Argonaut.Decode.decodeJson json)
  configuration <- Platform.Node.Inventory.graphImpl executable [ "config", "list" ] { encoding: "utf8", timeout: 20000, maxBuffer: 33554432 }
  require (Data.Nullable.toMaybe configuration.status == Data.Maybe.Just 0 && Data.Maybe.isNothing (Data.Nullable.toMaybe configuration.error)) "Cannot inspect pnpm build settings"
  configurationText <- Data.Maybe.maybe (Effect.Exception.throw "pnpm returned no build settings") pure (Data.Nullable.toMaybe configuration.stdout)
  configurationJson <- Data.Either.either Effect.Exception.throw pure (Data.Argonaut.Parser.jsonParser configurationText)
  settings <- Data.Either.either (Effect.Exception.throw <<< show) pure (Data.Argonaut.Decode.decodeJson configurationJson) :: Effect.Effect (Foreign.Object.Object Data.Argonaut.Core.Json)
  require (not (Data.Foldable.any (flip Foreign.Object.member settings) [ "patchedDependencies", "globalPnpmfile", "pnpmfile" ])) "Unsupported pnpm computed file/patch setting requires an explicit frontend build-input declaration"
  pure workspaces

configClosure :: String -> String -> Effect.Effect (Array String)
configClosure root path = do
  config <- Platform.Node.Frontend.readConfigImpl (root <> "/" <> path)
  require (Data.Maybe.isNothing (Data.Nullable.toMaybe config.error)) ("Invalid TypeScript config: " <> path)
  object <- Data.Maybe.maybe (Effect.Exception.throw ("Expected TypeScript config object: " <> path)) pure (Data.Argonaut.Core.toObject config.config)
  case Foreign.Object.lookup "extends" object of
    Data.Maybe.Nothing ->
      pure [ path ]
    Data.Maybe.Just value -> do
      parent <- Data.Maybe.maybe (Effect.Exception.throw ("Unsupported TypeScript config extends: " <> path)) pure (Data.Argonaut.Core.toString value)
      require (Data.String.Utils.startsWith "." parent) ("Unsupported nonlocal TypeScript config extends: " <> parent)
      resolved <- Node.Path.resolve [ root, Node.Path.dirname path ] parent >>= relative root
      parents <- configClosure root resolved
      pure ([ path ] <> parents)

discover :: String -> String -> Phoenix.Frontend.Inputs.Json.Assets -> Data.Argonaut.Core.Json -> Effect.Effect Phoenix.Frontend.Inputs.Json.Graph
discover root pnpm assets vite = do
  Node.Process.chdir (root <> "/js")
  workspaces <- workspaceClosure pnpm
  manifests <- Data.Traversable.traverse (\workspace -> relative root (workspace.path <> "/package.json")) workspaces
  require (canonical manifests == canonical (map _.manifest assets.recipes)) ("Workspace closure differs from supported build recipes: " <> show manifests)
  Data.Foldable.traverse_
    ( \recipe -> do
        manifest <- Build.Json.readSync (root <> "/" <> recipe.manifest) :: Effect.Effect Data.Argonaut.Core.Json
        scripts <- field "scripts" manifest :: Effect.Effect (Foreign.Object.Object String)
        Data.Foldable.traverse_ (\name -> require (Foreign.Object.lookup name scripts == Foreign.Object.lookup name recipe.scripts) ("Unsupported frontend lifecycle script: " <> recipe.manifest <> "#" <> name)) [ "build", "prebuild", "postbuild" ]
        Data.Foldable.traverse_ (\(Data.Tuple.Tuple name expected) -> require (Foreign.Object.lookup name scripts == Data.Maybe.Just expected) ("Unsupported frontend build script: " <> recipe.manifest <> "#" <> name)) (Foreign.Object.toUnfoldable recipe.scripts :: Array (Data.Tuple.Tuple String String))
    )
    assets.recipes
  entryBuild <- field "build" vite :: Effect.Effect Data.Argonaut.Core.Json
  rolldown <- field "rolldownOptions" entryBuild :: Effect.Effect Data.Argonaut.Core.Json
  entry <- field "input" rolldown >>= relative root
  appRoot <- field "root" vite >>= relative root
  publicDirectory <- field "publicDir" vite >>= relative root
  require (appRoot == "js/app/src" && entry == "js/app/src/index.tsx" && publicDirectory == "js/app/static") "Unsupported Vite entry/root/public-directory boundary"
  publicResult <- Platform.Node.Inventory.graphImpl "find" [ root <> "/" <> publicDirectory, "-type", "f", "-printf", "%p\n" ] { encoding: "utf8", timeout: 20000, maxBuffer: 33554432 }
  require (Data.Nullable.toMaybe publicResult.status == Data.Maybe.Just 0 && Data.Maybe.isNothing (Data.Nullable.toMaybe publicResult.error)) "Cannot inspect computed public asset directory"
  publicText <- Data.Maybe.maybe (Effect.Exception.throw "Public asset discovery returned no result") pure (Data.Nullable.toMaybe publicResult.stdout)
  publicFiles <- Data.Traversable.traverse (relative root) (Data.Array.filter (_ /= "") (Data.String.Utils.lines publicText))
  require (canonical publicFiles == canonical assets.publicFiles) ("Computed public asset declaration mismatch: " <> show { missing: Data.Array.difference assets.publicFiles publicFiles, added: Data.Array.difference publicFiles assets.publicFiles })
  relayConfig <- Platform.Node.Frontend.relayConfigImpl (root <> "/js/app/relay.config.js")
  relaySource <- field "src" relayConfig :: Effect.Effect String
  relaySchema <- field "schema" relayConfig :: Effect.Effect String
  relayExcludes <- field "excludes" relayConfig :: Effect.Effect (Array String)
  require (relaySource == "./src" && relaySchema == "./schema.graphql" && canonical relayExcludes == canonical [ "**/node_modules/**", "**/__mocks__/**", "**/__generated__/**" ]) "Unsupported Relay source/schema/generated boundary"
  relayRoots <- Platform.Node.Frontend.filesImpl (root <> "/" <> appRoot) [ "**/__generated__/**", "**/__mocks__/**" ] [ "**/*.ts", "**/*.tsx" ] >>= Data.Traversable.traverse (relative root)
  let
    configs = canonical (Data.Array.concatMap _.configs assets.recipes)
  configFiles <- canonical <<< Data.Array.concat <$> Data.Traversable.traverse (configClosure root) configs
  parsed <- Data.Traversable.traverse
    ( \path -> do
        original <- Platform.Node.Frontend.readConfigImpl (root <> "/" <> path)
        value <- Platform.Node.Frontend.parseConfigImpl original.config (root <> "/" <> Node.Path.dirname path)
        require (Data.Array.null value.errors) ("TypeScript configuration parse failed: " <> path)
        files <- Data.Traversable.traverse (relative root) value.fileNames
        pure { path, options: value.options, files: if path == "js/app/tsconfig.json" then [] else Data.Array.filter (not <<< nonProduct) files }
    )
    configs
  let
    roots = canonical (Data.Array.filter (not <<< nonProduct) relayRoots <> Data.Array.concatMap _.files parsed <> [ entry ])
  seen <- Effect.Ref.new Data.Set.empty
  edges <- Effect.Ref.new []
  moduleAssets <- Effect.Ref.new []
  viteResolve <- field "resolve" vite :: Effect.Effect Data.Argonaut.Core.Json
  aliases <- field "alias" viteResolve :: Effect.Effect (Array Data.Argonaut.Core.Json)
  aliasPairs <- Data.Traversable.traverse
    ( \alias -> do
        object <- Data.Either.either (Effect.Exception.throw <<< show) pure (Data.Argonaut.Decode.decodeJson alias) :: Effect.Effect (Foreign.Object.Object Data.Argonaut.Core.Json)
        let
          name = Foreign.Object.lookup "find" object >>= Data.Argonaut.Core.toString
        case name of
          Data.Maybe.Nothing ->
            do
              pattern <- Platform.Node.Frontend.aliasPatternImpl alias
              require (Data.Array.elem pattern [ "/^\\/?@vite\\/env/", "/^\\/?@vite\\/client/" ]) ("Unsupported frontend alias pattern: " <> pattern)
              pure []
          Data.Maybe.Just find -> do
            replacement <- field "replacement" alias
            pure [ { find, replacement } ]
    )
    aliases
  app <- Data.Maybe.maybe (Effect.Exception.throw "App TypeScript configuration is missing") pure (Data.Array.find (_.path >>> (_ == "js/app/tsconfig.json")) parsed)
  let
    visit path options = do
      visited <- Effect.Ref.read seen
      unless (Data.Set.member path visited) do
        require (not (nonProduct path)) ("Production import reaches test/fixture source: " <> path)
        present <- Platform.Node.Build.existsImpl (root <> "/" <> path)
        require present ("Missing build input: " <> path)
        Effect.Ref.modify_ (Data.Set.insert path) seen
        text <- Platform.Node.Build.readImpl (root <> "/" <> path)
        imports <- Platform.Node.Frontend.importsImpl text
        when (Data.String.Utils.endsWith ".css" path || Data.String.Utils.endsWith ".grammar" path) do
          require (not (Data.Foldable.any (\marker -> Data.String.contains (Data.String.Pattern marker) text) [ "url(", "@external" ])) ("Unsupported computed frontend asset reference: " <> path)
          when (Data.String.contains (Data.String.Pattern "@import") text) (require (not (Data.Array.null imports.importedFiles)) ("Unparsed frontend asset import: " <> path))
        Data.Foldable.traverse_
          ( \reference -> do
              let
                request = reference.fileName
                plain = Data.Maybe.fromMaybe request (Data.Array.head (Data.String.split (Data.String.Pattern "?") request))
                alias = Data.Array.find (\item -> plain == item.find || Data.String.Utils.startsWith (item.find <> "/") plain) (Data.Array.concat aliasPairs)
                mapped = Data.Maybe.maybe plain (\item -> Data.String.replace (Data.String.Pattern item.find) (Data.String.Replacement item.replacement) plain) alias
                local = Data.String.Utils.startsWith "." plain || Data.Maybe.isJust alias
              resolution <- Platform.Node.Frontend.resolveImpl mapped (root <> "/" <> path) options
              literal <- Node.Path.resolve [ root, Node.Path.dirname path ] plain
              literalExists <- if Data.String.Utils.startsWith "." plain then Platform.Node.Build.existsImpl literal else pure false
              literalFile <- if literalExists then not <$> Platform.Node.Build.directoryImpl literal else pure false
              target <-
                if literalFile then pure (Data.Maybe.Just literal)
                else case Data.Nullable.toMaybe resolution.resolvedModule of
                  Data.Maybe.Just resolved ->
                    pure (Data.Maybe.Just resolved.resolvedFileName)
                  Data.Maybe.Nothing ->
                    if Data.String.Utils.startsWith "." plain then do
                      exists <- Platform.Node.Build.existsImpl literal
                      if exists then pure (Data.Maybe.Just literal)
                      else if Data.String.Utils.endsWith ".graphql" plain then pure (Data.Maybe.Just (literal <> ".ts"))
                      else Effect.Exception.throw ("Unresolved local frontend import: " <> path <> " -> " <> request)
                    else do
                      require (not local) ("Unresolved frontend alias: " <> path <> " -> " <> request)
                      pure Data.Maybe.Nothing
              case target of
                Data.Maybe.Nothing ->
                  pure unit
                Data.Maybe.Just absolute ->
                  unless (Data.String.contains (Data.String.Pattern "/node_modules/") absolute) do
                    resolved <- relative root absolute
                    Effect.Ref.modify_ (_ <> [ { from: path, request, target: resolved } ]) edges
                    unless (generated assets resolved) do
                      if Data.String.Utils.endsWith ".ts" resolved || Data.String.Utils.endsWith ".tsx" resolved || Data.String.Utils.endsWith ".js" resolved then visit resolved options
                      else do
                        Effect.Ref.modify_ (_ <> [ resolved ]) moduleAssets
                        visit resolved options
                      when (request /= plain) (Effect.Ref.modify_ (_ <> [ resolved ]) moduleAssets)
          )
          (imports.importedFiles <> imports.referencedFiles)
  visit "js/.pnpmfile.cjs" app.options
  dependencyModules <- Data.Set.toUnfoldable <$> Effect.Ref.read seen :: Effect.Effect (Array String)
  Data.Foldable.traverse_ (\project -> Data.Foldable.traverse_ (\path -> unless (generated assets path) (visit path project.options)) project.files) parsed
  Data.Foldable.traverse_ (\path -> unless (generated assets path) (visit path app.options)) (roots <> [ "js/app/vite.config.mts", "js/app/relay.config.js" ])
  observedEdges <- Effect.Ref.read edges
  observedAssets <- canonical <$> Effect.Ref.read moduleAssets
  require (canonical observedAssets == canonical assets.moduleFiles) ("Module asset declaration mismatch: " <> show { missing: Data.Array.difference assets.moduleFiles observedAssets, added: Data.Array.difference observedAssets assets.moduleFiles })
  require (canonical (map _.manifest assets.generators) == canonical (map _.manifest (Data.Array.filter (\recipe -> Foreign.Object.member "generate" recipe.scripts) assets.recipes))) "Computed build asset declarations do not cover the generator recipes"
  Data.Foldable.traverse_
    ( \generator -> do
        manifest <- Build.Json.readSync (root <> "/" <> generator.manifest) :: Effect.Effect Data.Argonaut.Core.Json
        scripts <- field "scripts" manifest :: Effect.Effect (Foreign.Object.Object String)
        script <- Data.Maybe.maybe (Effect.Exception.throw "Missing generator script") pure (Foreign.Object.lookup generator.script scripts)
        let
          schema = "../../../" <> generator.input
          destination = " -o ./" <> Node.Path.relative (Node.Path.dirname generator.manifest) generator.output
        require (Data.String.contains (Data.String.Pattern schema) script && Data.String.contains (Data.String.Pattern destination) script && Data.String.contains (Data.String.Pattern "openapi-typescript") script) ("Unsupported computed build asset: " <> generator.input)
        Platform.Node.Build.existsImpl (root <> "/" <> generator.input) >>= flip require ("Missing computed build asset: " <> generator.input)
    )
    assets.generators
  viteDependencies <- field "configFileDependencies" vite :: Effect.Effect (Array String)
  viteFiles <- Data.Traversable.traverse (relative root) (Data.Array.filter (not <<< Data.String.contains (Data.String.Pattern "/node_modules/")) viteDependencies)
  importedFiles <- Data.Set.toUnfoldable <$> Effect.Ref.read seen :: Effect.Effect (Array String)
  let
    dependencies = canonical (manifests <> dependencyModules <> [ "js/package.json", "js/.npmrc", "js/pnpm-lock.yaml", "js/pnpm-workspace.yaml" ])
    sources = Data.Array.difference (canonical (Data.Array.filter (not <<< generated assets) importedFiles <> configFiles <> viteFiles <> publicFiles <> map _.input assets.generators <> [ "js/app/relay.config.js", "js/app/schema.graphql" ])) dependencies
  pure { inventory: { dependencies, sources }, workspaces, edges: observedEdges, configs: configFiles, roots, publicDirectory, publicFiles: canonical publicFiles, moduleAssets: observedAssets, generators: assets.generators }

validate :: Phoenix.Frontend.Inputs.Json.Inventory -> Phoenix.Frontend.Inputs.Json.Inventory -> Effect.Effect Unit
validate expected actual = do
  let
    expectedFiles = expected.dependencies <> expected.sources
    actualFiles = actual.dependencies <> actual.sources
    missing = Data.Array.difference actualFiles expectedFiles
    unused = Data.Array.difference expectedFiles actualFiles
  require (Data.Array.length (canonical expectedFiles) == Data.Array.length expectedFiles) "Duplicate product inventory entry"
  require (Data.Array.null missing && Data.Array.null unused && canonical expected.dependencies == canonical actual.dependencies) ("Product input mismatch: " <> show { missing, unused })

reject :: String -> String -> Effect.Effect Unit -> Effect.Effect String
reject label path action = do
  result <- Effect.Exception.try action
  case result of
    Data.Either.Left error -> do
      let
        message = Effect.Exception.message error
      require (Data.String.contains (Data.String.Pattern path) message) ("Negative control failed for the wrong reason: " <> label <> ": " <> message)
      pure message
    Data.Either.Right _ ->
      Effect.Exception.throw ("Negative control was accepted: " <> label)

controls :: String -> String -> Phoenix.Frontend.Inputs.Json.Assets -> Data.Argonaut.Core.Json -> Phoenix.Frontend.Inputs.Json.Inventory -> Phoenix.Frontend.Inputs.Json.Graph -> String -> Effect.Effect Unit
controls output root assets vite expected graph pnpm = do
  let
    added = "js/app/frontendInventoryControl.ts"
    missing = "js/app/src/index.tsx"
    unused = "js/app/frontendInventoryUnused.ts"
    public = "js/app/static/.frontend-inventory-control.txt"
  originalEntry <- Platform.Node.Build.readImpl (root <> "/" <> missing)
  Platform.Node.Build.writeImpl (root <> "/" <> added) "export {};\n"
  Platform.Node.Build.writeImpl (root <> "/" <> missing) (originalEntry <> "\nimport \"../frontendInventoryControl\";\n")
  addedGraph <- discover root pnpm assets vite
  require (Data.Foldable.any (\edge -> edge.from == missing && edge.target == added) addedGraph.edges) "Added-source control did not traverse the actual import edge"
  addedResult <- reject "added source omitted from inventory" added (validate expected addedGraph.inventory)
  Platform.Node.Build.writeImpl (root <> "/" <> missing) originalEntry
  missingResult <- reject "missing existing source entry" missing (validate (expected { sources = Data.Array.filter (_ /= missing) expected.sources }) graph.inventory)
  Platform.Node.Build.writeImpl (root <> "/" <> unused) "export {};\n"
  unusedGraph <- discover root pnpm assets vite
  unusedResult <- reject "unused existing source entry" unused (validate (expected { sources = expected.sources <> [ unused ] }) unusedGraph.inventory)
  Platform.Node.Build.writeImpl (root <> "/" <> public) "computed-path public asset rejection control\n"
  publicResult <- reject "computed public asset omitted from declarations" public (void (discover root pnpm assets vite))
  Platform.Node.Build.writeImpl (output <> "/controls.json") (Data.Argonaut.Core.stringifyWithIndent 2 (Data.Argonaut.Encode.encodeJson { added: { path: added, rejected: true, message: addedResult }, missing: { path: missing, rejected: true, message: missingResult }, unused: { path: unused, rejected: true, message: unusedResult }, computedAsset: { path: public, rejected: true, message: publicResult } }) <> "\n")

main :: Effect.Effect Unit
main = Effect.Aff.launchAff_ do
  arguments <- Effect.Class.liftEffect (Data.Array.drop 2 <$> Node.Process.argv)
  case arguments of
    [ "export", input, output ] ->
      Effect.Class.liftEffect (Platform.Node.Build.copyImpl input output)
    [ mode, output, root, pnpm, declarationPath, inventoryPath ] -> do
      started <- Effect.Class.liftEffect Node.Process.uptime
      assets <- Effect.Class.liftEffect (Build.Json.readSync declarationPath) :: Effect.Aff.Aff Phoenix.Frontend.Inputs.Json.Assets
      vite <- Control.Promise.toAffE (Platform.Node.Frontend.viteConfigImpl (root <> "/js/app/package.json") (Data.Argonaut.Encode.encodeJson { configFile: root <> "/js/app/vite.config.mts" }))
      Effect.Class.liftEffect do
        graph <- discover root pnpm assets vite
        Platform.Node.Build.mkdirImpl output
        Platform.Node.Build.writeImpl (output <> "/inventory.json") (Data.Argonaut.Core.stringifyWithIndent 2 (Data.Argonaut.Encode.encodeJson graph.inventory) <> "\n")
        Platform.Node.Build.writeImpl (output <> "/graph.json") (Data.Argonaut.Core.stringifyWithIndent 2 (Data.Argonaut.Encode.encodeJson graph) <> "\n")
        when (mode == "check") do
          expected <- Build.Json.readSync inventoryPath
          validate expected graph.inventory
          controls output root assets vite expected graph pnpm
        require (Data.Array.elem mode [ "check", "generate" ]) "Unknown frontend product-input operation"
        finished <- Node.Process.uptime
        require (finished - started < 60.0) "Frontend product-input validation exceeded 60 seconds"
        Platform.Node.Build.writeImpl (output <> "/receipt.json") (Data.Argonaut.Core.stringifyWithIndent 2 (Data.Argonaut.Encode.encodeJson { mode, validated: mode == "check", sourceCount: Data.Array.length graph.inventory.sources, dependencyCount: Data.Array.length graph.inventory.dependencies, importEdges: Data.Array.length graph.edges, publicAssets: Data.Array.length graph.publicFiles, elapsedSeconds: finished - started }) <> "\n")
    _ ->
      Effect.Class.liftEffect (Effect.Exception.throw "Expected frontend product-input operation and declared inputs")
