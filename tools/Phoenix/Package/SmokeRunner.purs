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
import Data.String as Data.String
import Data.Traversable as Data.Traversable
import Effect as Effect
import Effect.Aff as Effect.Aff
import Effect.Class as Effect.Class
import Effect.Exception as Effect.Exception
import Effect.Ref as Effect.Ref
import Effect.Uncurried as Effect.Uncurried
import Foreign.Object as Foreign.Object
import Node.Encoding as Node.Encoding
import Node.FS.Aff as Node.FS.Aff
import Node.FS.Stats as Node.FS.Stats
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

smokeChildren :: Effect.Aff.Aff (Array Test.Process.Observation)
smokeChildren = do
  let
    owner = show (Data.Newtype.unwrap Node.Process.pid :: Int)
  text <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 ("/proc/" <> owner <> "/task/" <> owner <> "/children")
  ids <- Data.Traversable.traverse
    (Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Invalid smoke-owner child identity")) pure <<< Data.Int.fromString)
    (Data.Array.filter (_ /= "") (Data.String.split (Data.String.Pattern " ") (Data.String.trim text)))
  Data.Array.catMaybes <$> Data.Traversable.traverse Test.Process.observe ids

run :: String -> String -> String -> Effect.Aff.Aff Unit
run output contextPath mode = do
  started <- Effect.Class.liftEffect Test.Deadline.now
  let
    stallCucumber = mode == "stall-cucumber"
    interruptRequest = mode == "interrupt-request"
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
  httpStarted <- Effect.Class.liftEffect (Effect.Ref.new 0)
  httpClosed <- Effect.Class.liftEffect (Effect.Ref.new 0)
  httpGroups <- Effect.Class.liftEffect (Effect.Ref.new [])
  requestInterrupted <- Effect.Class.liftEffect (Effect.Ref.new false)
  httpFailure <- Effect.Class.liftEffect (Effect.Ref.new Data.Maybe.Nothing)
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
            children <- smokeChildren
            unless (Data.Array.null serverSurvivors && Data.Array.null cucumberSurvivors && Data.Array.null children) (Effect.Aff.delay (Effect.Aff.Milliseconds 10.0) *> reaped)
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
      httpScopesStarted <- Effect.Class.liftEffect (Effect.Ref.read httpStarted)
      httpScopesClosed <- Effect.Class.liftEffect (Effect.Ref.read httpClosed)
      requestGroups <- Effect.Class.liftEffect (Effect.Ref.read httpGroups)
      requestGroupSurvivors <- Data.Array.concat <$> Data.Traversable.traverse Test.Process.group requestGroups
      remainingChildren <- smokeChildren
      assert "HTTP request category survived outer cleanup" (httpScopesStarted == httpScopesClosed && Data.Array.null requestGroupSurvivors && Data.Array.null remainingChildren)
      Effect.Class.liftEffect (Effect.Ref.write true cleanupReference)
      progress <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 (output <> "/progress.json")
      Effect.Class.liftEffect (Effect.Ref.write (Data.Maybe.Just progress) progressReference)
      finished <- Effect.Class.liftEffect Test.Deadline.now
      Build.Json.write (output <> "/cleanup.json") { server, cucumber, serverSurvivors, cucumberSurvivors, httpScopesStarted, httpScopesClosed, requestGroups, requestGroupSurvivors, remainingChildren, httpOwnerPid: Data.Newtype.unwrap Node.Process.pid, root, stateExists, httpAndGrpcPortsRebound: true, ownedProcessesTerminated: true, elapsedMs: finished - started }
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
      Build.Json.write (output <> "/ownership.json") { root, pid, port, grpcPort, arguments, environment, stallCucumber, interruptRequest }
      Build.Json.write (output <> "/inputs.json") { launcher, package: context.package, pythonEnvironment: context.pythonEnvironment, runtimes: context.runtimes, arguments, environment, port, grpcPort, startingState: "Fresh isolated TEST directory; new SQLite database; no credentials, fixtures or providers", ownerPid: Data.Newtype.unwrap Node.Process.pid }
      failure <- Effect.Class.liftEffect (Effect.Ref.read spawnFailure)
      Data.Foldable.traverse_ Effect.Aff.throwError failure
      Test.Deadline.progress runtime "setup" "A" "outer runner owns Phoenix group and temporary directory"
      let
        env = Foreign.Object.fromHomogeneous { "HOME": cwd, "TMPDIR": cwd, "PHOENIX_PACKAGE_SMOKE_CONTEXT": contextPath, "PHOENIX_PACKAGE_SMOKE_REPORT": output, "PHOENIX_PACKAGE_SMOKE_STARTED": show started }
      current <- Effect.Class.liftEffect Test.Deadline.now
      let
        runHttp request = do
          assert "Unexpected HTTP request in package smoke" (Data.Array.elem request.label [ "health", "index", "asset", "projects", "after-stop", "active-request", "stalled-health" ] && Data.Array.elem request.path [ "/healthz", "/", "/assets/rolldown-runtime-DLMaRju-.js", "/v1/projects", "/assets/index-BOHcm13E.js" ])
          now <- Effect.Class.liftEffect Test.Deadline.now
          let
            remaining = Test.Deadline.budget context.policy started (Data.Maybe.Just started) false now
            activeControl = interruptRequest && request.label == "active-request"
            timeout = if activeControl then remaining else min 1500 remaining
            seconds = if activeControl then show (Data.Int.toNumber remaining / 1000.0) else "1"
            url = "http://127.0.0.1:" <> show port <> request.path
          assert "HTTP request exhausted the original scenario budget" (remaining > 0)
          Effect.Class.liftEffect (Effect.Ref.modify_ (_ + 1) httpStarted)
          Build.Json.write (output <> "/http-current.json") { request, url, ownerPid: Data.Newtype.unwrap Node.Process.pid, timeoutMs: timeout, activeControl }
          let
            command = Platform.Process.Node.Managed.run
              { timeout: Effect.Aff.Milliseconds (Data.Int.toNumber timeout), maxStdout: 1048576, stderr: Platform.Process.Node.Managed.Capture 1048576, processTable: context.processTable }
              { cwd: root, env: environment, stdin: "" }
              context.curl
              ([ "--noproxy", "*", "--silent", "--show-error", "--connect-timeout", "1", "--max-time", seconds, "--output", output <> "/" <> request.label <> "-body.txt", "--dump-header", output <> "/" <> request.label <> "-headers.txt", "--write-out", "%{http_code}" ] <> (if activeControl then [ "--limit-rate", "1024", "--no-buffer" ] else []) <> [ url ])
            interruptActive = do
              children <- smokeChildren
              cucumberPid <- Effect.Class.liftEffect (Effect.Ref.read cucumberReference) >>= Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Active request has no independently observed Cucumber owner")) pure
              let
                candidates = Data.Array.filter (\process -> process.pid /= pid && process.pid /= cucumberPid && not (Test.Process.terminated process)) children
              headersExist <- Effect.Class.liftEffect (Platform.Node.Build.existsImpl (output <> "/active-request-headers.txt"))
              bodyExists <- Effect.Class.liftEffect (Platform.Node.Build.existsImpl (output <> "/active-request-body.txt"))
              if Data.Array.length candidates == 1 && headersExist && bodyExists then do
                curl <- Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Missing active request process")) pure (Data.Array.head candidates)
                headers <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 (output <> "/active-request-headers.txt")
                receivedBytes <- Node.FS.Stats.size <$> Node.FS.Aff.stat (output <> "/active-request-body.txt")
                expectedBytes <- Node.FS.Stats.size <$> Node.FS.Aff.stat (context.static <> "/assets/index-BOHcm13E.js")
                if not (Data.String.contains (Data.String.Pattern "HTTP/1.1 200") headers && receivedBytes > 0.0 && receivedBytes < expectedBytes) then Effect.Aff.delay (Effect.Aff.Milliseconds 5.0) *> interruptActive
                else do
                  commandLine <- Node.FS.Aff.readTextFile Node.Encoding.UTF8 ("/proc/" <> show curl.pid <> "/cmdline")
                  assert "Active HTTP request escaped the outer owner's process group contract" (curl.ppid == Data.Newtype.unwrap Node.Process.pid && curl.group == curl.pid && Data.String.contains (Data.String.Pattern url) commandLine && remaining > 30000)
                  Effect.Class.liftEffect (Effect.Ref.modify_ (\groups -> Data.Array.snoc groups curl.group) httpGroups)
                  before <- Effect.Class.liftEffect Test.Deadline.now
                  Effect.Class.liftEffect (Platform.Node.ProcessControl.signalImpl cucumberPid "SIGSTOP")
                  Effect.Aff.delay (Effect.Aff.Milliseconds 50.0)
                  cucumberState <- Test.Process.observe cucumberPid
                  curlAfter <- Test.Process.observe curl.pid
                  after <- Effect.Class.liftEffect Test.Deadline.now
                  assert "Cucumber was not interrupted during a live request" (Data.Maybe.maybe false (\process -> Data.Array.elem process.state [ "T", "t" ]) cucumberState && Data.Maybe.maybe false (\process -> process.startedTicks == curl.startedTicks && process.group == curl.group && not (Test.Process.terminated process)) curlAfter)
                  partialBytesAfter <- Node.FS.Stats.size <$> Node.FS.Aff.stat (output <> "/active-request-body.txt")
                  assert "The HTTP body completed before interruption was observed" (partialBytesAfter > 0.0 && partialBytesAfter < expectedBytes)
                  Build.Json.write (output <> "/request-interruption-observed.json") { request, url, curlBefore: curl, curlAfter, cucumberState, expectedBytes, receivedBytes, partialBytesAfter, timeoutMs: timeout, beforeMs: before - started, afterMs: after - started, independentOwnerPid: Data.Newtype.unwrap Node.Process.pid }
                  Effect.Class.liftEffect (Effect.Ref.write true requestInterrupted)
              else Effect.Aff.delay (Effect.Aff.Milliseconds 5.0) *> interruptActive
          result <- Effect.Aff.bracket (Effect.Aff.forkAff command)
            ( \fiber -> do
                Effect.Aff.killFiber (Effect.Aff.error "Outer owner closed HTTP request scope") fiber
                Effect.Class.liftEffect (Effect.Ref.modify_ (_ + 1) httpClosed)
            )
            ( \fiber -> do
                when activeControl interruptActive
                Effect.Aff.joinFiber fiber
            )
          observed <- Data.Either.either (Effect.Aff.throwError <<< Effect.Aff.error <<< show) pure result
          Build.Json.write (output <> "/" <> request.label <> "-outer-http.json") { request, url, ownerPid: Data.Newtype.unwrap Node.Process.pid, status: observed.status, httpStatus: observed.stdout, stderr: observed.stderr }
          pure { id: request.id, status: observed.status, stdout: observed.stdout, stderr: observed.stderr }
        serveHttp previous = do
          exists <- Effect.Class.liftEffect (Platform.Node.Build.existsImpl (output <> "/http-request.json"))
          next <- if exists then Data.Maybe.Just <$> (Build.Json.read (output <> "/http-request.json") :: Effect.Aff.Aff Phoenix.Package.Smoke.Json.Request) else pure Data.Maybe.Nothing
          case next of
            Data.Maybe.Just request | request.id > previous -> do
              assert "HTTP request sequence skipped or duplicated an operation" (request.id == previous + 1)
              response <- runHttp request
              Build.Json.write (output <> "/http-response.pending.json") response
              Node.FS.Aff.rename (output <> "/http-response.pending.json") (output <> "/http-response.json")
              serveHttp request.id
            _ -> do
              Effect.Aff.delay (Effect.Aff.Milliseconds 5.0)
              serveHttp previous
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
            health <- runHttp { id: 0, label: "stalled-health", path: "/healthz" }
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
        Effect.Aff.bracket
          (Effect.Aff.forkAff (Effect.Aff.catchError (serveHttp 0) (\error -> Effect.Class.liftEffect (Effect.Ref.write (Data.Maybe.Just error) httpFailure))))
          (Effect.Aff.killFiber (Effect.Aff.error "Outer smoke owner closed HTTP executor"))
          ( \_ -> do
              cucumberPid <- readCucumberOwner
              when stallCucumber (observeStall cucumberPid)
              when interruptRequest do
                let
                  wait = do
                    executorFailure <- Effect.Class.liftEffect (Effect.Ref.read httpFailure)
                    Data.Foldable.traverse_ Effect.Aff.throwError executorFailure
                    observed <- Effect.Class.liftEffect (Effect.Ref.read requestInterrupted)
                    unless observed (Effect.Aff.delay (Effect.Aff.Milliseconds 5.0) *> wait)
                wait
                Effect.Aff.throwError (Effect.Aff.error "Interrupted Cucumber during an active real HTTP request")
              Effect.Aff.joinFiber fiber
          )
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
  Build.Json.write (output <> "/receipt.json") { accepted: Data.Either.isRight outcome, selected: 1, package: context.package, launcher: context.package <> "/bin/phoenix", elapsedMs: finished - started, limitMs: context.policy.singleMilliseconds, subprocessCleanupComplete: cleaned, stallCucumber, interruptRequest, failure, concurrency: 1, node: Node.Process.version }
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
            [ "failure-progress.json", "progress.json", "interruption-observed.json", "request-interruption-observed.json", "cleanup.json", "receipt.json" ]
    )
  assert "Smoke did not clean all outer-owned resources within its deadline" (cleaned && finished - started < Data.Int.toNumber context.policy.singleMilliseconds)
  if stallCucumber || interruptRequest then do
    assert "Stopped Cucumber unexpectedly passed the smoke" (Data.Either.isLeft outcome)
    observed <- Effect.Class.liftEffect (Platform.Node.Build.existsImpl (output <> (if interruptRequest then "/request-interruption-observed.json" else "/interruption-observed.json")))
    assert "Control did not actually observe its required interruption boundary" observed
    innerCleanup <- Effect.Class.liftEffect (Platform.Node.Build.existsImpl (output <> "/shutdown.json"))
    assert "Control reached ordinary inner shutdown instead of preventing it" (not innerCleanup)
    Build.Json.write (output <> "/control.json") { rejected: true, stoppedEventLoopObserved: true, interruptRequest, innerShutdownAbsent: true, cleanupComplete: cleaned, elapsedMs: finished - started, limitMs: context.policy.singleMilliseconds }
  else Data.Either.either Effect.Aff.throwError pure outcome

main :: Effect.Effect Unit
main = Effect.Aff.launchAff_ do
  arguments <- Effect.Class.liftEffect (Data.Array.drop 2 <$> Node.Process.argv)
  case arguments of
    [ output, contextPath, mode ] | Data.Array.elem mode [ "smoke", "stall-cucumber", "interrupt-request" ] ->
      run output contextPath mode
    _ ->
      Effect.Aff.throwError (Effect.Aff.error "Package smoke requires output, context and smoke, stall-cucumber or interrupt-request mode")
