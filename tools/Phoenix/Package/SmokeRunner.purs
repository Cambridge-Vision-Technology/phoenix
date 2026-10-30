module Phoenix.Package.SmokeRunner (main) where

import Prelude

import Build.Json as Build.Json
import Build.Output as Build.Output
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
import Data.Int as Data.Int
import Data.Maybe as Data.Maybe
import Data.Newtype as Data.Newtype
import Data.Nullable as Data.Nullable
import Effect as Effect
import Effect.Aff as Effect.Aff
import Effect.Class as Effect.Class
import Effect.Exception as Effect.Exception
import Effect.Ref as Effect.Ref
import Effect.Uncurried as Effect.Uncurried
import Foreign.Object as Foreign.Object
import Node.Encoding as Node.Encoding
import Node.FS.Aff as Node.FS.Aff
import Node.Process as Node.Process
import Phoenix.Package.Smoke.Json as Phoenix.Package.Smoke.Json
import Platform.Node.Build as Platform.Node.Build
import Platform.Node.Port as Platform.Node.Port
import Platform.Node.ProcessControl as Platform.Node.ProcessControl
import Platform.Process.Node.Managed as Platform.Process.Node.Managed
import Test.Deadline as Test.Deadline
import Test.Process as Test.Process

assert :: String -> Boolean -> Effect.Aff.Aff Unit
assert message condition = unless condition (Effect.Aff.throwError (Effect.Aff.error message))

phoenixPort :: Int -> Effect.Aff.Aff Int
phoenixPort port = Effect.Aff.makeAff \complete -> do
  server <- Platform.Node.Port.createImpl
  Platform.Node.Port.errorImpl server (Effect.Uncurried.mkEffectFn1 (complete <<< Data.Either.Left))
  Platform.Node.Port.listenImpl server { port, host: "127.0.0.1" } do
    address <- Platform.Node.Port.addressImpl server
    Platform.Node.Port.closeImpl server (complete (Data.Maybe.maybe (Data.Either.Left (Effect.Aff.error "Phoenix port listener has no address")) (Data.Either.Right <<< _.port) (Data.Nullable.toMaybe address)))
  pure Effect.Aff.nonCanceler

run :: String -> String -> Boolean -> Effect.Aff.Aff Unit
run output contextPath stallCucumber = do
  started <- Effect.Class.liftEffect Test.Deadline.now
  context <- Build.Json.read contextPath :: Effect.Aff.Aff Phoenix.Package.Smoke.Json.Context
  assert "Invalid package smoke deadline policy" (Test.Deadline.policyValid context.policy && context.policy.singleMilliseconds <= 60000)
  cwd <- Effect.Class.liftEffect Node.Process.cwd
  Effect.Class.liftEffect (Platform.Node.Build.mkdirImpl output)
  serverReference <- Effect.Class.liftEffect (Effect.Ref.new Data.Maybe.Nothing)
  cucumberReference <- Effect.Class.liftEffect (Effect.Ref.new Data.Maybe.Nothing)
  rootReference <- Effect.Class.liftEffect (Effect.Ref.new Data.Maybe.Nothing)
  portsReference <- Effect.Class.liftEffect (Effect.Ref.new Data.Maybe.Nothing)
  cleanupReference <- Effect.Class.liftEffect (Effect.Ref.new false)
  progressReference <- Effect.Class.liftEffect (Effect.Ref.new Data.Maybe.Nothing)
  spawnFailure <- Effect.Class.liftEffect (Effect.Ref.new Data.Maybe.Nothing)
  let
    runtime = { policy: context.policy, started, scenario: "Start the native Phoenix package offline", report: output, timeout: context.timeout }
    cleanup = do
      server <- Effect.Class.liftEffect (Effect.Ref.read serverReference)
      cucumber <- Effect.Class.liftEffect (Effect.Ref.read cucumberReference)
      root <- Effect.Class.liftEffect (Effect.Ref.read rootReference)
      let
        removeState = Data.Foldable.traverse_ (\path -> Node.FS.Aff.rm' path { recursive: true, force: false, maxRetries: 0, retryDelay: 0 }) root
      Effect.Aff.finally removeState do
        Data.Foldable.traverse_ (Test.Deadline.stopGroup context.policy.cleanupReserveMilliseconds) server
        Data.Foldable.traverse_ (Test.Deadline.stopGroup context.policy.cleanupReserveMilliseconds) cucumber
        let
          reaped = do
            serverSurvivors <- Data.Maybe.maybe (pure []) Test.Process.group server
            cucumberSurvivors <- Data.Maybe.maybe (pure []) Test.Process.group cucumber
            unless (Data.Array.null serverSurvivors && Data.Array.null cucumberSurvivors) (Effect.Aff.delay (Effect.Aff.Milliseconds 10.0) *> reaped)
        reaped
        ports <- Effect.Class.liftEffect (Effect.Ref.read portsReference)
        Data.Foldable.traverse_
          ( \selected -> do
              http <- phoenixPort selected.port
              grpc <- phoenixPort selected.grpcPort
              assert "Owned Phoenix listeners survived cleanup" (http == selected.port && grpc == selected.grpcPort)
          )
          ports
      stateExists <- Data.Maybe.maybe (pure false) (Effect.Class.liftEffect <<< Platform.Node.Build.existsImpl) root
      assert "Owned Phoenix temporary state survived cleanup" (not stateExists)
      serverSurvivors <- Data.Maybe.maybe (pure []) Test.Process.group server
      cucumberSurvivors <- Data.Maybe.maybe (pure []) Test.Process.group cucumber
      Effect.Class.liftEffect (Effect.Ref.write true cleanupReference)
      progress <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 (output <> "/progress.json")
      Effect.Class.liftEffect (Effect.Ref.write (Data.Maybe.Just progress) progressReference)
      finished <- Effect.Class.liftEffect Test.Deadline.now
      Build.Json.write (output <> "/cleanup.json") { server, cucumber, serverSurvivors, cucumberSurvivors, root, stateExists, httpAndGrpcPortsRebound: true, ownedProcessesTerminated: true, elapsedMs: finished - started }
    work = do
      root <- Node.FS.Aff.mkdtemp "/tmp/phoenix-package-test-"
      Effect.Class.liftEffect (Effect.Ref.write (Data.Maybe.Just root) rootReference)
      port <- phoenixPort 0
      grpcPort <- phoenixPort 0
      assert "HTTP and gRPC free ports collide" (port /= grpcPort)
      Effect.Class.liftEffect (Effect.Ref.write (Data.Maybe.Just { port, grpcPort }) portsReference)
      let
        arguments = [ "--host", "127.0.0.1", "--port", show port, "--grpc-port", show grpcPort, "--no-internet" ]
        environment = Foreign.Object.fromHomogeneous
          { "HOME": root, "TMPDIR": root, "PATH": "/deliberately-empty-test-path", "PHOENIX_WORKING_DIR": root <> "/working", "PHOENIX_TELEMETRY_ENABLED": "false", "PHOENIX_ALLOW_EXTERNAL_RESOURCES": "false", "PHOENIX_DISABLE_AGENT_ASSISTANT": "true", "PHOENIX_ENABLE_MCP_SERVER": "false", "PHOENIX_LOG_MIGRATIONS": "false", "DO_NOT_TRACK": "1" }
        launcher = context.package <> "/bin/phoenix"
      child <- Effect.Class.liftEffect (Platform.Node.ProcessControl.spawnImpl launcher arguments { cwd: root, env: environment, detached: true, stdio: "inherit" })
      Effect.Class.liftEffect (Platform.Node.ProcessControl.onErrorImpl child (Effect.Uncurried.mkEffectFn1 (\error -> Effect.Ref.write (Data.Maybe.Just error) spawnFailure)))
      pid <- Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Phoenix launcher has no owned process identity")) pure (Data.Nullable.toMaybe (Platform.Node.ProcessControl.pidImpl child))
      Effect.Class.liftEffect (Effect.Ref.write (Data.Maybe.Just pid) serverReference)
      Build.Json.write (output <> "/ownership.json") { root, pid, port, grpcPort, arguments, environment, stallCucumber }
      Build.Json.write (output <> "/inputs.json") { launcher, package: context.package, pythonEnvironment: context.pythonEnvironment, runtimes: context.runtimes, arguments, environment, port, grpcPort, startingState: "Fresh isolated TEST directory; new SQLite database; no credentials, fixtures or providers", ownerPid: Data.Newtype.unwrap Node.Process.pid }
      failure <- Effect.Class.liftEffect (Effect.Ref.read spawnFailure)
      Data.Foldable.traverse_ Effect.Aff.throwError failure
      Test.Deadline.progress runtime "setup" "A" "outer runner owns Phoenix group and temporary directory"
      let
        env = Foreign.Object.fromHomogeneous { "HOME": cwd, "TMPDIR": cwd, "PHOENIX_PACKAGE_SMOKE_CONTEXT": contextPath, "PHOENIX_PACKAGE_SMOKE_REPORT": output, "PHOENIX_PACKAGE_SMOKE_STARTED": show started }
      current <- Effect.Class.liftEffect Test.Deadline.now
      let
        available = Test.Deadline.budget context.policy started (Data.Maybe.Just started) false current
        cucumber = Platform.Process.Node.Managed.run
          { timeout: Effect.Aff.Milliseconds (Data.Int.toNumber available), maxStdout: 8388608, stderr: Platform.Process.Node.Managed.Capture 8388608, processTable: context.processTable }
          { cwd: "/", env, stdin: "" }
          context.node
          [ context.cucumber, "--config", context.support <> "/cucumber.json", "--parallel", "0", "--import", context.support <> "/steps.mjs", "--format", "progress", "--format", "json:" <> output <> "/cucumber.json", "--name", "^Start the native Phoenix package offline$", context.feature ]
        readCucumberOwner = do
          exists <- Effect.Class.liftEffect (Platform.Node.Build.existsImpl (output <> "/cucumber-owner.json"))
          if exists then do
            owner <- Build.Json.read (output <> "/cucumber-owner.json") :: Effect.Aff.Aff { cucumberPid :: Int }
            observed <- Test.Process.observe owner.cucumberPid
            assert "Cucumber did not start in a separate owned group" (Data.Maybe.maybe false (\process -> process.ppid == Data.Newtype.unwrap Node.Process.pid && process.group == owner.cucumberPid && process.group /= pid) observed)
            Effect.Class.liftEffect (Effect.Ref.write (Data.Maybe.Just owner.cucumberPid) cucumberReference)
            pure owner.cucumberPid
          else Effect.Aff.delay (Effect.Aff.Milliseconds 10.0) *> readCucumberOwner
        observeStall cucumberPid = do
          observed <- Test.Process.observe cucumberPid
          if Data.Maybe.maybe false (\process -> Data.Array.elem process.state [ "T", "t" ]) observed then do
            marker <- Build.Json.read (output <> "/interruption.json") :: Effect.Aff.Aff { cucumberPid :: Int, serverPid :: Int, root :: String, port :: Int, health :: String }
            assert "Interruption did not target this real packaged server" (marker.cucumberPid == cucumberPid && marker.serverPid == pid && marker.root == root && marker.port == port && marker.health == "OK")
            server <- Test.Process.observe pid
            assert "Packaged Phoenix exited before the interruption control" (Data.Maybe.maybe false (\process -> process.ppid == Data.Newtype.unwrap Node.Process.pid && process.group == pid && not (Test.Process.terminated process)) server)
            response <- Platform.Process.Node.Managed.run
              { timeout: Effect.Aff.Milliseconds 1500.0, maxStdout: 1048576, stderr: Platform.Process.Node.Managed.Capture 1048576, processTable: context.processTable }
              { cwd: root, env: environment, stdin: "" }
              context.curl
              [ "--noproxy", "*", "--silent", "--show-error", "--max-time", "1", "--output", output <> "/stalled-health-body.txt", "--write-out", "%{http_code}", "http://127.0.0.1:" <> show port <> "/healthz" ]
            health <- Data.Either.either (Effect.Aff.throwError <<< Effect.Aff.error <<< show) pure response
            body <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 (output <> "/stalled-health-body.txt")
            assert "Phoenix was not serving health while Cucumber was stopped" (health.status == 0 && health.stdout == "200" && body == "OK")
            stateExists <- Effect.Class.liftEffect (Platform.Node.Build.existsImpl (root <> "/working"))
            assert "Interruption control did not create real temporary working state" stateExists
            stoppedAt <- Effect.Class.liftEffect Test.Deadline.now
            Build.Json.write (output <> "/interruption-observed.json") { cucumber: observed, server, stateExists, healthStatus: health.stdout, healthBody: body, elapsedMs: stoppedAt - started }
          else do
            assert "Cucumber exited instead of stopping its event loop" (Data.Maybe.maybe false (not <<< Test.Process.terminated) observed)
            Effect.Aff.delay (Effect.Aff.Milliseconds 10.0)
            observeStall cucumberPid
      result <- Effect.Aff.bracket (Effect.Aff.forkAff cucumber) (Effect.Aff.killFiber (Effect.Aff.error "Outer smoke owner closed Cucumber scope")) \fiber -> do
        cucumberPid <- readCucumberOwner
        when stallCucumber (observeStall cucumberPid)
        Effect.Aff.joinFiber fiber
      observed <- Data.Either.either (Effect.Aff.throwError <<< Effect.Aff.error <<< show) pure result
      Effect.Class.liftEffect do
        Platform.Node.Build.writeImpl (output <> "/stdout.txt") observed.stdout
        Platform.Node.Build.writeImpl (output <> "/stderr.txt") (Data.Maybe.fromMaybe "" observed.stderr)
        when (observed.status /= 0) do
          Build.Output.writeLine Node.Process.stderr observed.stdout (pure unit)
          Build.Output.writeLine Node.Process.stderr (Data.Maybe.fromMaybe "" observed.stderr) (pure unit)
      assert "Cucumber package smoke failed" (observed.status == 0)
      report <- Build.Json.read (output <> "/cucumber.json") :: Effect.Aff.Aff (Array { elements :: Array { name :: String, type :: String, steps :: Array { result :: { status :: String } } } })
      let
        selected = Data.Array.filter (\entry -> entry.type == "scenario") (Data.Array.concatMap _.elements report)
      assert "Package smoke selected zero, multiple or incomplete scenarios"
        (Data.Array.length selected == 1 && Data.Foldable.all (\entry -> entry.name == "Start the native Phoenix package offline" && not (Data.Array.null entry.steps) && Data.Foldable.all (\step -> step.result.status == "passed") entry.steps) selected)
  outcome <- Test.Deadline.guard runtime "pair" "A" (Data.Maybe.Just started)
    (Effect.Aff.attempt (Effect.Aff.finally cleanup (Test.Deadline.guard runtime "execution" "A" (Data.Maybe.Just started) work)))
  cleaned <- Effect.Class.liftEffect (Effect.Ref.read cleanupReference)
  finished <- Effect.Class.liftEffect Test.Deadline.now
  let
    failure = Data.Either.either (Data.Maybe.Just <<< Effect.Exception.message) (const Data.Maybe.Nothing) outcome
  Build.Json.write (output <> "/receipt.json") { accepted: Data.Either.isRight outcome, selected: 1, package: context.package, launcher: context.package <> "/bin/phoenix", elapsedMs: finished - started, limitMs: context.policy.singleMilliseconds, subprocessCleanupComplete: cleaned, stallCucumber, failure, concurrency: 1, node: Node.Process.version }
  when (Data.Either.isLeft outcome)
    ( do
        progress <- Effect.Class.liftEffect (Effect.Ref.read progressReference)
        Data.Foldable.traverse_ (Node.FS.Aff.writeTextFile Node.Encoding.UTF8 (output <> "/failure-progress.json")) progress
        Effect.Class.liftEffect do
          Data.Foldable.traverse_
            ( \name -> do
                exists <- Platform.Node.Build.existsImpl (output <> "/" <> name)
                when exists do
                  receipt <- Platform.Node.Build.readImpl (output <> "/" <> name)
                  Build.Output.writeLine Node.Process.stderr (name <> ": " <> receipt) (pure unit)
            )
            [ "failure-progress.json", "progress.json", "interruption-observed.json", "cleanup.json", "receipt.json" ]
    )
  assert "Smoke did not clean all outer-owned resources within its deadline" (cleaned && finished - started < Data.Int.toNumber context.policy.singleMilliseconds)
  if stallCucumber then do
    assert "Stopped Cucumber unexpectedly passed the smoke" (Data.Either.isLeft outcome)
    observed <- Effect.Class.liftEffect (Platform.Node.Build.existsImpl (output <> "/interruption-observed.json"))
    assert "Control did not actually observe the stopped Cucumber and healthy packaged server" observed
    innerCleanup <- Effect.Class.liftEffect (Platform.Node.Build.existsImpl (output <> "/shutdown.json"))
    assert "Control reached ordinary inner shutdown instead of preventing it" (not innerCleanup)
    Build.Json.write (output <> "/control.json") { rejected: true, stoppedEventLoopObserved: true, innerShutdownAbsent: true, cleanupComplete: cleaned, elapsedMs: finished - started, limitMs: context.policy.singleMilliseconds }
  else Data.Either.either Effect.Aff.throwError pure outcome

main :: Effect.Effect Unit
main = Effect.Aff.launchAff_ do
  arguments <- Effect.Class.liftEffect (Data.Array.drop 2 <$> Node.Process.argv)
  case arguments of
    [ output, contextPath, mode ] | mode == "smoke" || mode == "stall-cucumber" ->
      run output contextPath (mode == "stall-cucumber")
    _ ->
      Effect.Aff.throwError (Effect.Aff.error "Package smoke requires output, context and smoke or stall-cucumber mode")
