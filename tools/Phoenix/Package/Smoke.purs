module Phoenix.Package.Smoke (run) where

import Prelude

import Build.Json as Build.Json
import Control.Promise as Control.Promise
import Data.Argonaut.Decode as Data.Argonaut.Decode
import Data.Argonaut.Parser as Data.Argonaut.Parser
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
import Data.Int as Data.Int
import Data.Maybe as Data.Maybe
import Data.Newtype as Data.Newtype
import Data.String as Data.String
import Effect as Effect
import Effect.Aff as Effect.Aff
import Effect.Class as Effect.Class
import Effect.Exception as Effect.Exception
import Effect.Ref as Effect.Ref
import Foreign.Object as Foreign.Object
import Node.Encoding as Node.Encoding
import Node.FS.Aff as Node.FS.Aff
import Node.Process as Node.Process
import Phoenix.Package.Smoke.Json as Phoenix.Package.Smoke.Json
import Platform.Node.Build as Platform.Node.Build
import Platform.Node.ProcessControl as Platform.Node.ProcessControl
import Platform.Process.Node.Managed as Platform.Process.Node.Managed
import Test.Deadline as Test.Deadline
import Test.Process as Test.Process

assert :: String -> Boolean -> Effect.Aff.Aff Unit
assert message condition = unless condition (Effect.Aff.throwError (Effect.Aff.error message))

run :: Effect.Effect (Control.Promise.Promise Unit)
run = Control.Promise.fromAff do
  contextPath <- Effect.Class.liftEffect (Node.Process.lookupEnv "PHOENIX_PACKAGE_SMOKE_CONTEXT") >>= Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Missing TEST package smoke context")) pure
  context <- Build.Json.read contextPath :: Effect.Aff.Aff Phoenix.Package.Smoke.Json.Context
  report <- Effect.Class.liftEffect (Node.Process.lookupEnv "PHOENIX_PACKAGE_SMOKE_REPORT") >>= Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Missing package smoke report directory")) pure
  startedText <- Effect.Class.liftEffect (Node.Process.lookupEnv "PHOENIX_PACKAGE_SMOKE_STARTED") >>= Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Missing package smoke start time")) pure
  startedJson <- Data.Either.either (Effect.Aff.throwError <<< Effect.Aff.error) pure (Data.Argonaut.Parser.jsonParser startedText)
  started <- Data.Either.either (Effect.Aff.throwError <<< Effect.Aff.error <<< show) pure (Data.Argonaut.Decode.decodeJson startedJson)
  let
    runtime = { policy: context.policy, started, scenario: "Start the native Phoenix package offline", report, timeout: context.timeout }
    checkpoint = Test.Deadline.progress runtime "execution" "A"
    deadline = Test.Deadline.guard runtime "execution" "A" (Data.Maybe.Just started)
  assert "Invalid shared deadline policy" (Test.Deadline.policyValid context.policy && context.policy.singleMilliseconds <= 60000)
  owner <- Build.Json.read (report <> "/ownership.json") :: Effect.Aff.Aff Phoenix.Package.Smoke.Json.Ownership
  Build.Json.write (report <> "/cucumber-owner.pending.json") { cucumberPid: Data.Newtype.unwrap Node.Process.pid }
  Node.FS.Aff.rename (report <> "/cucumber-owner.pending.json") (report <> "/cucumber-owner.json")
  outcome <- Effect.Aff.attempt
    ( Effect.Aff.catchError
        ( deadline do
            requests <- Effect.Class.liftEffect (Effect.Ref.new [])
            let
              root = owner.root
              pid = owner.pid
              port = owner.port
              base = "http://127.0.0.1:" <> show port
              arguments = owner.arguments
              environment = owner.environment
              request label path = do
                current <- Effect.Class.liftEffect Test.Deadline.now
                let
                  available = Test.Deadline.budget context.policy started (Data.Maybe.Just started) false current
                assert "HTTP request has no remaining smoke budget" (available > 0)
                observed <- Platform.Process.Node.Managed.run
                  { timeout: Effect.Aff.Milliseconds (Data.Int.toNumber (min 1500 available)), maxStdout: 1048576, stderr: Platform.Process.Node.Managed.Capture 1048576, processTable: context.processTable }
                  { cwd: root, env: environment, stdin: "" }
                  context.curl
                  [ "--noproxy", "*", "--silent", "--show-error", "--connect-timeout", "1", "--max-time", "1", "--output", report <> "/" <> label <> "-body.txt", "--dump-header", report <> "/" <> label <> "-headers.txt", "--write-out", "%{http_code}", base <> path ]
                result <- Data.Either.either (Effect.Aff.throwError <<< Effect.Aff.error <<< show) pure observed
                observations <- Effect.Class.liftEffect (Effect.Ref.modify (\history -> Data.Array.snoc history { method: "GET", url: base <> path, status: result.status, httpStatus: result.stdout, stderr: result.stderr }) requests)
                Build.Json.write (report <> "/requests.json") observations
                pure result
            Test.Deadline.progress runtime "startup" "A" "owned launcher process started; waiting for health"
            let
              ready = do
                response <- request "health" "/healthz"
                if response.status == 0 && response.stdout == "200" then pure unit
                else do
                  state <- Test.Process.observe pid
                  assert "Phoenix exited before readiness" (Data.Maybe.maybe false (not <<< Test.Process.terminated) state)
                  Effect.Aff.delay (Effect.Aff.Milliseconds 100.0)
                  ready
            ready
            health <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 (report <> "/health-body.txt")
            assert "Health response is not OK" (health == "OK")
            checkpoint "GET /healthz = 200 OK"
            command <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 ("/proc/" <> show pid <> "/cmdline")
            exported <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 ("/proc/" <> show pid <> "/environ")
            let
              commandArguments = Data.Array.filter (_ /= "") (Data.String.split (Data.String.Pattern "\x0000") command)
              exportedEntries = Data.String.split (Data.String.Pattern "\x0000") exported
              wasm = context.runtimes <> "/share/phoenix/python-3.12.0.wasm"
            assert ("Launcher did not exec Python with unchanged user arguments: " <> show commandArguments) (commandArguments == [ context.pythonEnvironment <> "/bin/python3.13", "-m", "phoenix.server.main", "serve" ] <> arguments)
            assert "Launcher lost the evaluator PATH" (Data.Array.elem ("PATH=" <> context.runtimes <> "/bin:/deliberately-empty-test-path") exportedEntries)
            assert "Launcher lost the WASM dependency" (Data.Array.elem ("PHOENIX_WASM_BINARY_PATH=" <> wasm) exportedEntries)
            runtimePaths <- Effect.Class.liftEffect do
              deno <- Platform.Node.Build.existsImpl (context.runtimes <> "/bin/deno")
              monty <- Platform.Node.Build.existsImpl (context.runtimes <> "/bin/monty")
              binary <- Platform.Node.Build.existsImpl wasm
              pure { deno, monty, wasm: binary }
            assert "A launcher runtime dependency is unavailable" (runtimePaths.deno && runtimePaths.monty && runtimePaths.wasm)
            Build.Json.write (report <> "/launcher.json") { pid, commandArguments, runtimePaths, runtimePath: context.runtimes <> "/bin", wasm, execPreservedPid: true }
            when owner.stallCucumber do
              let
                cucumberPid = Data.Newtype.unwrap Node.Process.pid
              Build.Json.write (report <> "/interruption.json") { cucumberPid, serverPid: pid, root, port, health: "OK" }
              Effect.Class.liftEffect (Platform.Node.ProcessControl.signalImpl cucumberPid "SIGSTOP")
            indexResponse <- request "index" "/"
            assert "UI index did not return 200" (indexResponse.status == 0 && indexResponse.stdout == "200")
            index <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 (report <> "/index-body.txt")
            Data.Foldable.traverse_ (\marker -> assert ("UI index is missing " <> marker) (Data.String.contains (Data.String.Pattern marker) index))
              [ "<!DOCTYPE html>", "<title>Phoenix</title>", "<div id=\"root\">", "type=\"module\" src=\"/assets/index-BOHcm13E.js\"" ]
            manifest <- Build.Json.read (context.static <> "/.vite/manifest.json") :: Effect.Aff.Aff (Foreign.Object.Object { file :: String })
            asset <- Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Manifest is missing the hashed runtime asset")) pure (Foreign.Object.lookup "_rolldown-runtime-DLMaRju-.js" manifest)
            assert "Approved hashed asset changed" (asset.file == "assets/rolldown-runtime-DLMaRju-.js")
            assetResponse <- request "asset" ("/" <> asset.file)
            assert "Hashed asset did not return 200" (assetResponse.status == 0 && assetResponse.stdout == "200")
            expectedAsset <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 (context.static <> "/" <> asset.file)
            servedAsset <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 (report <> "/asset-body.txt")
            assert "HTTP asset bytes differ from the installed producer artifact" (servedAsset == expectedAsset && servedAsset /= "")
            checkpoint "GET / and manifest-selected hashed asset = 200; UI and exact asset bytes asserted"
            projectsResponse <- request "projects" "/v1/projects"
            assert "Read-only projects API did not return 200" (projectsResponse.status == 0 && projectsResponse.stdout == "200")
            projects <- Build.Json.read (report <> "/projects-body.txt") :: Effect.Aff.Aff { data :: Array { id :: String, name :: String, description :: String }, next_cursor :: Data.Maybe.Maybe String }
            assert "Fresh database projects response differs from the fixed expected default project"
              (projects.data == [ { id: "UHJvamVjdDox", name: "default", description: "Default project" } ] && projects.next_cursor == Data.Maybe.Nothing)
            Build.Json.write (report <> "/assertions.json") { health: "OK", indexMarkers: true, asset: asset.file, exactInstalledAssetBytes: true, projects, expectedProjects: [ { id: "UHJvamVjdDox", name: "default", description: "Default project" } ], httpStatuses: [ 200, 200, 200, 200 ] }
            checkpoint "GET /v1/projects = 200; fixed fresh-database response asserted"
            Effect.Class.liftEffect (Platform.Node.ProcessControl.signalImpl pid "SIGTERM")
            let
              stopped = do
                state <- Test.Process.observe pid
                unless (Data.Maybe.isNothing state) (Effect.Aff.delay (Effect.Aff.Milliseconds 20.0) *> stopped)
            stopped
            closed <- request "after-stop" "/healthz"
            assert "Server still responds after SIGTERM" (closed.status /= 0 && closed.stdout == "000")
            Build.Json.write (report <> "/shutdown.json") { pid, signal: "SIGTERM", processTerminated: true, healthConnectionRefused: true }
            checkpoint "SIGTERM reached exec-replaced server; process terminated and listener closed"
        )
        ( \error -> do
            progress <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 (report <> "/progress.json")
            Node.FS.Aff.writeTextFile Node.Encoding.UTF8 (report <> "/failure-progress.json") progress
            Effect.Aff.throwError error
        )
    )
  finished <- Effect.Class.liftEffect Test.Deadline.now
  Build.Json.write (report <> "/journey.json") { package: context.package, launcher: context.package <> "/bin/phoenix", elapsedMs: finished - started, limitMs: context.policy.singleMilliseconds, accepted: Data.Either.isRight outcome, failure: Data.Either.either (Data.Maybe.Just <<< Effect.Exception.message) (const Data.Maybe.Nothing) outcome }
  Data.Either.either Effect.Aff.throwError pure outcome
  assert "Smoke cleanup exceeded the shared 60-second deadline" (finished - started < Data.Int.toNumber context.policy.singleMilliseconds)
