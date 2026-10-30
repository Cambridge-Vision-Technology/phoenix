module Phoenix.Package.SmokeRunner (main) where

import Prelude

import Build.Json as Build.Json
import Build.Output as Build.Output
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
import Data.Int as Data.Int
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Effect as Effect
import Effect.Aff as Effect.Aff
import Effect.Class as Effect.Class
import Effect.Exception as Effect.Exception
import Effect.Ref as Effect.Ref
import Effect.Uncurried as Effect.Uncurried
import Foreign.Object as Foreign.Object
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

run :: String -> String -> Effect.Aff.Aff Unit
run output contextPath = do
  started <- Effect.Class.liftEffect Test.Deadline.now
  context <- Build.Json.read contextPath :: Effect.Aff.Aff Phoenix.Package.Smoke.Json.Context
  assert "Invalid package healthcheck deadline policy" (Test.Deadline.policyValid context.policy && context.policy.singleMilliseconds <= 60000)
  Effect.Class.liftEffect (Platform.Node.Build.mkdirImpl output)
  serverReference <- Effect.Class.liftEffect (Effect.Ref.new Data.Maybe.Nothing)
  rootReference <- Effect.Class.liftEffect (Effect.Ref.new Data.Maybe.Nothing)
  spawnFailure <- Effect.Class.liftEffect (Effect.Ref.new Data.Maybe.Nothing)
  cleanupReference <- Effect.Class.liftEffect (Effect.Ref.new false)
  let
    runtime = { policy: context.policy, started, scenario: "Start the native Phoenix package offline", report: output, timeout: context.timeout }
    cleanup = do
      server <- Effect.Class.liftEffect (Effect.Ref.read serverReference)
      root <- Effect.Class.liftEffect (Effect.Ref.read rootReference)
      Effect.Aff.finally
        (Data.Foldable.traverse_ (\path -> Node.FS.Aff.rm' path { recursive: true, force: false, maxRetries: 0, retryDelay: 0 }) root)
        ( Data.Foldable.traverse_
            ( \pid -> do
                observed <- Test.Process.group pid
                when (Data.Foldable.any (not <<< Test.Process.terminated) observed) do
                  Effect.Class.liftEffect (Platform.Node.ProcessControl.signalImpl (-pid) "SIGTERM")
                  shutdownStarted <- Effect.Class.liftEffect Test.Deadline.now
                  let
                    wait = do
                      remaining <- Test.Process.group pid
                      now <- Effect.Class.liftEffect Test.Deadline.now
                      when (Data.Foldable.any (not <<< Test.Process.terminated) remaining && now - shutdownStarted < Data.Int.toNumber context.policy.terminationGraceMilliseconds)
                        (Effect.Aff.delay (Effect.Aff.Milliseconds 10.0) *> wait)
                  Effect.Aff.finally (Test.Deadline.stopGroup context.policy.cleanupReserveMilliseconds pid) wait
                survivors <- Test.Process.group pid
                assert "Phoenix process group survived healthcheck cleanup" (Data.Foldable.all Test.Process.terminated survivors)
            )
            server
        )
      stateExists <- Data.Maybe.maybe (pure false) (Effect.Class.liftEffect <<< Platform.Node.Build.existsImpl) root
      assert "Phoenix temporary TEST state survived cleanup" (not stateExists)
      Effect.Class.liftEffect (Effect.Ref.write true cleanupReference)
      Build.Json.write (output <> "/cleanup.json") { server, temporaryStateRemoved: true, processGroupTerminated: true }
    work = do
      root <- Node.FS.Aff.mkdtemp "/tmp/phoenix-package-test-"
      Effect.Class.liftEffect (Effect.Ref.write (Data.Maybe.Just root) rootReference)
      let
        arguments = [ "--host", "127.0.0.1", "--port", "6006", "--grpc-port", "4317", "--no-internet" ]
        environment = Foreign.Object.fromHomogeneous
          { "HOME": root, "TMPDIR": root, "PATH": "/deliberately-empty-test-path", "PHOENIX_WORKING_DIR": root <> "/working", "PHOENIX_TELEMETRY_ENABLED": "false", "PHOENIX_ALLOW_EXTERNAL_RESOURCES": "false", "PHOENIX_DISABLE_AGENT_ASSISTANT": "true", "PHOENIX_ENABLE_MCP_SERVER": "false", "PHOENIX_LOG_MIGRATIONS": "false", "DO_NOT_TRACK": "1" }
        launcher = context.package <> "/bin/phoenix"
      Test.Deadline.progress runtime "startup" "A" "fresh TEST directory created; starting packaged executable on sandbox loopback"
      child <- Effect.Class.liftEffect (Platform.Node.ProcessControl.spawnImpl launcher arguments { cwd: root, env: environment, detached: true, stdio: "inherit" })
      Effect.Class.liftEffect (Platform.Node.ProcessControl.onErrorImpl child (Effect.Uncurried.mkEffectFn1 (\error -> Effect.Ref.write (Data.Maybe.Just error) spawnFailure)))
      pid <- Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Phoenix launcher has no owned process identity")) pure (Data.Nullable.toMaybe (Platform.Node.ProcessControl.pidImpl child))
      Effect.Class.liftEffect (Effect.Ref.write (Data.Maybe.Just pid) serverReference)
      Build.Json.write (output <> "/ownership.json") { root, pid, started }
      Build.Json.write (output <> "/inputs.json") { launcher, arguments, environment, startingState: "Fresh isolated TEST directory and SQLite database; no credentials or providers" }
      failure <- Effect.Class.liftEffect (Effect.Ref.read spawnFailure)
      Data.Foldable.traverse_ Effect.Aff.throwError failure
      current <- Effect.Class.liftEffect Test.Deadline.now
      let
        available = Test.Deadline.budget context.policy started (Data.Maybe.Just started) false current
        env = Foreign.Object.fromHomogeneous { "HOME": root, "TMPDIR": root, "PHOENIX_PACKAGE_SMOKE_CONTEXT": contextPath, "PHOENIX_PACKAGE_SMOKE_REPORT": output }
      result <- Platform.Process.Node.Managed.run
        { timeout: Effect.Aff.Milliseconds (Data.Int.toNumber available), maxStdout: 8388608, stderr: Platform.Process.Node.Managed.Capture 8388608, processTable: context.processTable }
        { cwd: "/", env, stdin: "" }
        context.node
        [ context.cucumber, "--config", context.support <> "/cucumber.json", "--parallel", "0", "--import", context.support <> "/steps.mjs", "--format", "progress", "--format", "json:" <> output <> "/cucumber.json", "--name", "^Start the native Phoenix package offline$", context.feature ]
      observed <- Data.Either.either (Effect.Aff.throwError <<< Effect.Aff.error <<< show) pure result
      Effect.Class.liftEffect do
        Build.Output.writeLine Node.Process.stderr observed.stdout (pure unit)
        Build.Output.writeLine Node.Process.stderr (Data.Maybe.fromMaybe "" observed.stderr) (pure unit)
      assert "Cucumber package healthcheck failed" (observed.status == 0)
      report <- Build.Json.read (output <> "/cucumber.json") :: Effect.Aff.Aff (Array { elements :: Array { name :: String, type :: String, steps :: Array { result :: { status :: String } } } })
      let
        selected = Data.Array.filter (\entry -> entry.type == "scenario") (Data.Array.concatMap _.elements report)
      assert "Package healthcheck selected zero, multiple or incomplete scenarios"
        (Data.Array.length selected == 1 && Data.Foldable.all (\entry -> entry.name == runtime.scenario && not (Data.Array.null entry.steps) && Data.Foldable.all (\step -> step.result.status == "passed") entry.steps) selected)
  outcome <- Effect.Aff.attempt
    ( Test.Deadline.guard runtime "pair" "A" (Data.Maybe.Just started)
        (Effect.Aff.finally cleanup (Test.Deadline.guard runtime "execution" "A" (Data.Maybe.Just started) work))
    )
  cleaned <- Effect.Class.liftEffect (Effect.Ref.read cleanupReference)
  finished <- Effect.Class.liftEffect Test.Deadline.now
  let
    failure = Data.Either.either (Data.Maybe.Just <<< Effect.Exception.message) (const Data.Maybe.Nothing) outcome
    receipt = { accepted: Data.Either.isRight outcome, selected: 1, package: context.package, elapsedMs: finished - started, limitMs: context.policy.singleMilliseconds, cleanupComplete: cleaned, failure, concurrency: 1 }
  Build.Json.write (output <> "/receipt.json") receipt
  when (Data.Either.isLeft outcome) do
    progress <- Effect.Class.liftEffect (Platform.Node.Build.readImpl (output <> "/progress.json"))
    Effect.Class.liftEffect (Build.Output.writeLine Node.Process.stderr progress (pure unit))
  Data.Either.either Effect.Aff.throwError pure outcome
  assert "Healthcheck did not clean all resources within its deadline" (cleaned && finished - started < Data.Int.toNumber context.policy.singleMilliseconds)

main :: Effect.Effect Unit
main = Effect.Aff.launchAff_ do
  arguments <- Effect.Class.liftEffect (Data.Array.drop 2 <$> Node.Process.argv)
  case arguments of
    [ output, contextPath ] -> run output contextPath
    _ -> Effect.Aff.throwError (Effect.Aff.error "Package healthcheck requires output and context")
