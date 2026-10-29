module Phoenix.Python.Inputs (main) where

import Prelude

import Build.Json as Build.Json
import Control.Monad.Rec.Class as Control.Monad.Rec.Class
import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
import Data.Int as Data.Int
import Data.Map as Data.Map
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Data.String as Data.String
import Data.String.CodeUnits as Data.String.CodeUnits
import Data.String.Utils as Data.String.Utils
import Data.Traversable as Data.Traversable
import Effect as Effect
import Effect.Exception as Effect.Exception
import Effect.Ref as Effect.Ref
import Node.FS.Sync as Node.FS.Sync
import Node.Path as Node.Path
import Node.Process as Node.Process
import Phoenix.Python.Inputs.Json as Phoenix.Python.Inputs.Json
import Platform.Node.Build as Platform.Node.Build
import Platform.Node.Inventory as Platform.Node.Inventory

require :: Boolean -> String -> Effect.Effect Unit
require condition message = unless condition (Effect.Exception.throw message)

canonical :: Array String -> Array String
canonical = Data.Array.sort <<< Data.Array.nub

within :: String -> String -> Boolean
within directory path = path == directory || Data.String.Utils.startsWith (directory <> "/") path

excluded :: String -> Boolean
excluded path = Data.Foldable.any (\prefix -> within ("src/phoenix/" <> prefix) path) [ "client", "evals", "otel", "server/static" ]
  || Data.Foldable.any (\part -> Data.Array.elem part [ "__pycache__", "tests", "test", "fixtures", "__tests__", "__fixtures__" ]) (Data.String.split (Data.String.Pattern "/") path)

files :: String -> String -> Effect.Effect (Array String)
files root path = do
  present <- Platform.Node.Build.existsImpl (root <> "/" <> path)
  require present ("Missing Python build path: " <> path)
  directory <- Platform.Node.Build.directoryImpl (root <> "/" <> path)
  if directory then do
    entries <- Platform.Node.Build.entriesImpl (root <> "/" <> path)
    Data.Array.concat <$> Data.Traversable.traverse (\entry -> files root (path <> "/" <> entry)) (Data.Array.filter (\entry -> not (excluded (path <> "/" <> entry))) entries)
  else pure [ path ]

type Import = { moduleName :: String, names :: Array String }
type Cache = Effect.Ref.Ref (Data.Map.Map String { text :: String, imports :: Array Import })

parseImports :: String -> Effect.Effect (Array Import)
parseImports text = do
  let
    lines = Data.String.Utils.lines text
  result <- Control.Monad.Rec.Class.tailRecM
    ( \cursor -> case Data.Array.index lines cursor.index of
        Data.Maybe.Nothing ->
          pure (Control.Monad.Rec.Class.Done cursor.state)
        Data.Maybe.Just line -> do
          state <- step cursor.state line
          pure (Control.Monad.Rec.Class.Loop { index: cursor.index + 1, state })
    )
    { index: 0, state: { pending: "", moduleName: "", names: [], imports: [] } }
  require (result.pending == "") "Incomplete CPython import AST"
  pure result.imports
  where
  literal prefix line = Data.String.stripPrefix (Data.String.Pattern prefix) line >>= Data.Array.head <<< Data.String.split (Data.String.Pattern "'")
  step state line
    | line == "Import(" || line == "ImportFrom(" = do
        require (state.pending == "") "Nested CPython import AST"
        pure (state { pending = line, moduleName = "", names = [] })
    | state.pending == "" = pure state
    | Data.String.Utils.startsWith "module=" line = do
        value <- Data.Maybe.maybe (Effect.Exception.throw ("Unsupported CPython module AST: " <> line)) pure (if line == "module=None," then Data.Maybe.Just "" else literal "module='" line)
        pure (state { moduleName = value })
    | Data.String.Utils.startsWith "alias(" line = do
        name <- Data.Maybe.maybe (Effect.Exception.throw ("Unsupported CPython alias AST: " <> line)) pure (literal "alias(name='" line)
        let
          names = state.names <> [ name ]
        pure (if state.pending == "Import(" && Data.String.contains (Data.String.Pattern "])") line then state { pending = "", imports = state.imports <> map (\moduleName -> { moduleName, names: [] }) names } else state { names = names })
    | Data.String.Utils.startsWith "level=" line = do
        level <- Data.Maybe.maybe (Effect.Exception.throw ("Unsupported CPython import level AST: " <> line)) pure (Data.String.stripPrefix (Data.String.Pattern "level=") line >>= Data.Array.head <<< Data.String.split (Data.String.Pattern ")") >>= Data.Int.fromString)
        require (state.pending == "ImportFrom(" && not (Data.Array.null state.names)) "Invalid CPython from-import AST"
        pure (state { pending = "", imports = state.imports <> [ { moduleName: Data.String.joinWith "" (Data.Array.replicate level ".") <> state.moduleName, names: state.names } ] })
    | otherwise = pure state

imports :: Cache -> String -> String -> String -> Effect.Effect (Array Import)
imports cache python root path = do
  text <- Platform.Node.Build.readImpl (root <> "/" <> path)
  existing <- Data.Map.lookup path <$> Effect.Ref.read cache
  case existing of
    Data.Maybe.Just value | value.text == text ->
      pure value.imports
    _ -> do
      result <- Platform.Node.Inventory.graphImpl python [ "-m", "ast", "--indent", "0", root <> "/" <> path ] { encoding: "utf8", timeout: 5000, maxBuffer: 33554432 }
      require (Data.Nullable.toMaybe result.status == Data.Maybe.Just 0 && Data.Maybe.isNothing (Data.Nullable.toMaybe result.error)) ("CPython AST parse failed: " <> path <> " " <> show result.stderr)
      ast <- Data.Maybe.maybe (Effect.Exception.throw ("CPython returned no AST: " <> path)) pure (Data.Nullable.toMaybe result.stdout)
      parsed <- parseImports ast
      Effect.Ref.modify_ (Data.Map.insert path { text, imports: parsed }) cache
      pure parsed

moduleTargets :: String -> String -> String -> Boolean -> Effect.Effect (Array String)
moduleTargets root origin request required = do
  let
    dots = Data.Array.length (Data.Array.takeWhile (_ == '.') (Data.String.CodeUnits.toCharArray request))
    suffix = Data.String.CodeUnits.drop dots request
    parts = Data.String.split (Data.String.Pattern ".") suffix
    parents = Data.String.split (Data.String.Pattern "/") (Node.Path.dirname origin)
    base = if dots == 0 then "src/" <> Data.String.joinWith "/" parts else Data.String.joinWith "/" (Data.Array.take (Data.Array.length parents - dots + 1) parents <> Data.Array.filter (_ /= "") parts)
    local = dots > 0 || within "phoenix" (Data.String.replaceAll (Data.String.Pattern ".") (Data.String.Replacement "/") request)
    registry = Data.Foldable.any (\prefix -> within ("src/phoenix/" <> prefix) base) [ "client", "evals", "otel" ]
  if not local || registry then pure []
  else do
    require (within "src/phoenix" base) ("Python import outside product boundary: " <> origin <> " -> " <> request)
    candidates <- Data.Array.filterA (\path -> Platform.Node.Build.existsImpl (root <> "/" <> path)) [ base <> ".py", base <> "/__init__.py" ]
    directory <- Platform.Node.Build.existsImpl (root <> "/" <> base)
    require (Data.Foldable.all (not <<< excluded) candidates) ("Python import reaches excluded source: " <> origin <> " -> " <> request)
    require (not required || not (Data.Array.null candidates) || directory) ("Unresolved local Python import: " <> origin <> " -> " <> request)
    pure candidates

discover :: Cache -> String -> String -> Phoenix.Python.Inputs.Json.Config -> Effect.Effect Phoenix.Python.Inputs.Json.Graph
discover cache python root config = do
  require (config.backend == "hatchling.build" && config.onlyPackages && config.packages == [ "src/phoenix" ]) "Unsupported Python package build recipe"
  require (canonical config.wheelKeys == [ "artifacts", "exclude", "packages" ] && canonical config.buildKeys == [ "only-packages", "targets" ]) "Unsupported Hatch build-input transformation"
  require (canonical config.excluded == canonical [ "src/phoenix/client/", "src/phoenix/evals/", "src/phoenix/otel/" ]) "Unsupported Python namespace exclusion boundary"
  require (Data.Foldable.all (within "src/phoenix") config.artifacts && Data.Array.elem "src/phoenix/server/static" config.artifacts) "Unsupported Python computed artifact boundary"
  scanned <- files root "src/phoenix"
  artifactFiles <- canonical <<< Data.Array.concat <$> Data.Traversable.traverse (files root) (Data.Array.filter (_ /= "src/phoenix/server/static") config.artifacts)
  selected <- Data.Array.filterA (\path -> if Data.Array.elem path artifactFiles then pure true else Platform.Node.Build.existsImpl (root <> "/" <> Node.Path.dirname path <> "/__init__.py")) scanned
  let
    packageFiles = canonical (Data.Array.filter (\path -> not (excluded path) && (not (Data.String.Utils.endsWith ".md" path || Data.String.Utils.endsWith ".rst" path) || Data.Array.elem path artifactFiles)) selected)
    modules = Data.Array.filter (Data.String.Utils.endsWith ".py") packageFiles
  edges <- Data.Array.concat <$> Data.Traversable.traverse
    ( \path -> do
        requests <- imports cache python root path
        Data.Array.concat <$> Data.Traversable.traverse
          ( \request -> do
              targets <- moduleTargets root path request.moduleName true
              nested <- Data.Array.concat <$> Data.Traversable.traverse (\name -> if name == "*" then pure [] else moduleTargets root path (request.moduleName <> (if Data.String.Utils.endsWith "." request.moduleName then "" else ".") <> name) false) request.names
              pure (map (\target -> { from: path, request: request.moduleName, target }) (canonical (targets <> nested)))
          )
          requests
    )
    modules
  let
    metadata = canonical ([ "pyproject.toml", config.version, config.readme ] <> config.licenses)
    inventory = canonical (packageFiles <> metadata)
  Data.Foldable.traverse_ (\path -> Platform.Node.Build.existsImpl (root <> "/" <> path) >>= flip require ("Missing Python build metadata: " <> path)) metadata
  Data.Foldable.traverse_ (\entry -> moduleTargets root "src/phoenix/__init__.py" (Data.Maybe.fromMaybe entry (Data.Array.head (Data.String.split (Data.String.Pattern ":") entry))) true >>= \targets -> require (not (Data.Array.null targets)) ("Python entry point is not packaged: " <> entry)) config.entries
  require (Data.Foldable.all (\edge -> Data.Array.elem edge.target packageFiles) edges) "Python import graph reaches a file outside the package inventory"
  pure { inventory, packageFiles, modules, artifacts: artifactFiles, artifactRoots: config.artifacts, edges, entries: config.entries }

validate :: Array String -> Array String -> Effect.Effect Unit
validate expected actual = do
  let
    missing = Data.Array.difference actual expected
    unused = Data.Array.difference expected actual
  require (Data.Array.length expected == Data.Array.length (canonical expected)) "Duplicate Python product inventory entry"
  require (Data.Array.null missing && Data.Array.null unused) ("Python product input mismatch: " <> show { missing, unused })

observe :: String -> String -> Phoenix.Python.Inputs.Json.Graph -> Effect.Effect Unit
observe root installed graph = do
  installedFiles <- files installed "phoenix"
  let
    packaged = canonical (map ("src/" <> _) (Data.Array.filter (\path -> not (excluded ("src/" <> path)) && not (Data.String.Utils.endsWith ".pyc" path)) installedFiles))
  validate graph.packageFiles packaged
  Data.Foldable.traverse_
    ( \path -> do
        expected <- Platform.Node.Build.readImpl (root <> "/" <> path)
        actual <- Platform.Node.Build.readImpl (installed <> "/" <> Data.String.CodeUnits.drop 4 path)
        require (expected == actual) ("Packaged computed artifact differs: " <> path)
    )
    graph.artifacts

reject :: String -> Effect.Effect Unit -> Effect.Effect String
reject path action = do
  result <- Effect.Exception.try action
  case result of
    Data.Either.Left error -> do
      let
        message = Effect.Exception.message error
      require (Data.String.contains (Data.String.Pattern path) message) ("Python input control failed for the wrong reason: " <> message)
      pure message
    Data.Either.Right _ ->
      Effect.Exception.throw ("Python input control was accepted: " <> path)

controls :: Cache -> String -> String -> String -> String -> Phoenix.Python.Inputs.Json.Config -> Array String -> Phoenix.Python.Inputs.Json.Graph -> Effect.Effect Unit
controls cache python output root installed config expected graph = do
  let
    migration = "src/phoenix/db/migrations/versions/python_inventory_control.py"
    prompt = "src/phoenix/server/agents/prompts/static/python-inventory-control.prompt"
    missing = "src/phoenix/server/main.py"
    unused = "python-inventory-unused.txt"
    addedRoot = root <> "-added-control"
    promptRoot = root <> "-prompt-control"
    installedRoot = root <> "-installed-control"
  Platform.Node.Build.copyImpl root addedRoot
  Platform.Node.Build.writeImpl (addedRoot <> "/" <> migration) "from phoenix.db import models\n"
  addedGraph <- discover cache python addedRoot config
  require (Data.Array.elem migration addedGraph.modules && Data.Foldable.any (\edge -> edge.from == migration) addedGraph.edges) "Migration control did not enter the actual Python import graph"
  addedResult <- reject migration (validate expected addedGraph.inventory)
  Platform.Node.Build.copyImpl root promptRoot
  Platform.Node.Build.writeImpl (promptRoot <> "/" <> prompt) "computed-path prompt inventory control\n"
  promptGraph <- discover cache python promptRoot config
  require (Data.Array.elem prompt promptGraph.artifacts) "Prompt control did not enter the declared artifact directory"
  promptResult <- reject prompt (validate expected promptGraph.inventory)
  newArtifactResult <- reject prompt (observe promptRoot installed promptGraph)
  missingResult <- reject missing (validate (Data.Array.filter (_ /= missing) expected) graph.inventory)
  Platform.Node.Build.writeImpl (root <> "/" <> unused) "existing but unused inventory control\n"
  unusedGraph <- discover cache python root config
  unusedResult <- reject unused (validate (expected <> [ unused ]) unusedGraph.inventory)
  artifact <- Data.Maybe.maybe (Effect.Exception.throw "Expected a non-Python prompt artifact") pure (Data.Array.find (\path -> within "src/phoenix/server/agents/prompts/static" path && not (Data.String.Utils.endsWith ".py" path)) graph.artifacts)
  Data.Foldable.traverse_
    ( \path -> do
        let
          relative = Data.String.CodeUnits.drop 4 path
        Platform.Node.Build.mkdirImpl (installedRoot <> "/" <> Node.Path.dirname relative)
        Platform.Node.Build.copyImpl (installed <> "/" <> relative) (installedRoot <> "/" <> relative)
    )
    graph.packageFiles
  Node.FS.Sync.unlink (installedRoot <> "/" <> Data.String.CodeUnits.drop 4 artifact)
  artifactResult <- reject artifact (observe root installedRoot graph)
  Platform.Node.Build.writeImpl (output <> "/controls.json") (Data.Argonaut.Core.stringifyWithIndent 2 (Data.Argonaut.Encode.encodeJson { addedMigration: { path: migration, message: addedResult }, addedPrompt: { path: prompt, message: promptResult }, unpackagedNewArtifact: { path: prompt, message: newArtifactResult }, missing: { path: missing, message: missingResult }, unused: { path: unused, message: unusedResult }, packagedArtifact: { path: artifact, message: artifactResult } }) <> "\n")

main :: Effect.Effect Unit
main = do
  arguments <- Data.Array.drop 2 <$> Node.Process.argv
  case arguments of
    [ "export", input, output ] ->
      Platform.Node.Build.copyImpl input output
    [ mode, output, root, configPath, inventoryPath, installed, python ] -> do
      started <- Node.Process.uptime
      cache <- Effect.Ref.new Data.Map.empty
      config <- Build.Json.readSync configPath
      graph <- discover cache python root config
      Platform.Node.Build.mkdirImpl output
      Platform.Node.Build.writeImpl (output <> "/inventory.json") (Data.Argonaut.Core.stringifyWithIndent 2 (Data.Argonaut.Encode.encodeJson graph.inventory) <> "\n")
      Platform.Node.Build.writeImpl (output <> "/graph.json") (Data.Argonaut.Core.stringifyWithIndent 2 (Data.Argonaut.Encode.encodeJson graph) <> "\n")
      when (mode == "check") do
        expected <- Build.Json.readSync inventoryPath
        validate expected graph.inventory
        observe root installed graph
        controls cache python output root installed config expected graph
      require (Data.Array.elem mode [ "generate", "check" ]) "Expected Python product-input operation"
      finished <- Node.Process.uptime
      require (finished - started < 60.0) "Python product-input check exceeded 60 seconds"
      Platform.Node.Build.writeImpl (output <> "/receipt.json") (Data.Argonaut.Core.stringifyWithIndent 2 (Data.Argonaut.Encode.encodeJson { mode, validated: mode == "check", entries: Data.Array.length graph.inventory, modules: Data.Array.length graph.modules, importEdges: Data.Array.length graph.edges, computedArtifacts: Data.Array.length graph.artifacts, elapsedSeconds: finished - started }) <> "\n")
    _ ->
      Effect.Exception.throw "Expected Python product-input operation and build inputs"
