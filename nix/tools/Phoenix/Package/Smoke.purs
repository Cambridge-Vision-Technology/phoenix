module Phoenix.Package.Smoke (run) where

import Prelude

import Build.Json as Build.Json
import Control.Promise as Control.Promise
import Data.Either as Data.Either
import Data.Maybe as Data.Maybe
import Effect as Effect
import Effect.Aff as Effect.Aff
import Effect.Class as Effect.Class
import Foreign.Object as Foreign.Object
import Node.Process as Node.Process
import Phoenix.Package.Smoke.Json as Phoenix.Package.Smoke.Json
import Platform.Process.Node as Platform.Process.Node
import Test.Deadline as Test.Deadline
import Test.Process as Test.Process

run :: Effect.Effect (Control.Promise.Promise Unit)
run = Control.Promise.fromAff do
  contextPath <- Effect.Class.liftEffect (Node.Process.lookupEnv "PHOENIX_PACKAGE_SMOKE_CONTEXT") >>= Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Missing TEST package smoke context")) pure
  context <- Build.Json.read contextPath :: Effect.Aff.Aff Phoenix.Package.Smoke.Json.Context
  report <- Effect.Class.liftEffect (Node.Process.lookupEnv "PHOENIX_PACKAGE_SMOKE_REPORT") >>= Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Missing healthcheck report directory")) pure
  owner <- Build.Json.read (report <> "/ownership.json") :: Effect.Aff.Aff Phoenix.Package.Smoke.Json.Ownership
  let
    runtime = { policy: context.policy, started: owner.started, scenario: "Start the native Phoenix package offline", report, timeout: context.timeout }
    ready = do
      response <- Effect.Class.liftEffect
        ( Platform.Process.Node.executeWith
            { timeout: Effect.Aff.Milliseconds 1500.0, maxBuffer: 4096 }
            { cwd: owner.root, env: Foreign.Object.empty, stdin: "" }
            context.curl
            [ "--noproxy", "*", "--silent", "--show-error", "--connect-timeout", "1", "--max-time", "1", "--output", "/dev/null", "--write-out", "%{http_code}", "http://127.0.0.1:6006/healthz" ]
        )
      observed <- Data.Either.either (Effect.Aff.throwError <<< Effect.Aff.error <<< show) pure response
      Build.Json.write (report <> "/health.json") observed
      state <- Test.Process.observe owner.pid
      unless (Data.Maybe.maybe false (not <<< Test.Process.terminated) state)
        (Effect.Aff.throwError (Effect.Aff.error "Packaged Phoenix exited before readiness"))
      if observed.status == 0 && observed.stdout == "200" then
        Test.Deadline.progress runtime "health" "A" "GET /healthz returned HTTP 200 from the native package"
      else do
        Effect.Aff.delay (Effect.Aff.Milliseconds 100.0)
        ready
  Test.Deadline.guard runtime "health" "A" (Data.Maybe.Just owner.started) ready
