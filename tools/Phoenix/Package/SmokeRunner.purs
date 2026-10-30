module Phoenix.Package.SmokeRunner (main) where

import Prelude

import Build.Json as Build.Json
import Build.Output as Build.Output
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
import Data.Int as Data.Int
import Data.Maybe as Data.Maybe
import Effect as Effect
import Effect.Aff as Effect.Aff
import Effect.Class as Effect.Class
import Foreign.Object as Foreign.Object
import Node.Process as Node.Process
import Phoenix.Package.Smoke.Json as Phoenix.Package.Smoke.Json
import Platform.Node.Build as Platform.Node.Build
import Platform.Process.Node.Managed as Platform.Process.Node.Managed
import Test.Deadline as Test.Deadline

main :: Effect.Effect Unit
main = Effect.Aff.launchAff_ do
  started <- Effect.Class.liftEffect Test.Deadline.now
  arguments <- Effect.Class.liftEffect (Data.Array.drop 2 <$> Node.Process.argv)
  case arguments of
    [ output, contextPath ] -> do
      context <- Build.Json.read contextPath :: Effect.Aff.Aff Phoenix.Package.Smoke.Json.Context
      cwd <- Effect.Class.liftEffect Node.Process.cwd
      Effect.Class.liftEffect (Platform.Node.Build.mkdirImpl output)
      let
        env = Foreign.Object.fromHomogeneous { "HOME": cwd, "TMPDIR": cwd, "PHOENIX_PACKAGE_SMOKE_CONTEXT": contextPath, "PHOENIX_PACKAGE_SMOKE_REPORT": output, "PHOENIX_PACKAGE_SMOKE_STARTED": show started }
      result <- Platform.Process.Node.Managed.run
        { timeout: Effect.Aff.Milliseconds (Data.Int.toNumber (context.policy.singleMilliseconds + context.policy.cleanupReserveMilliseconds)), maxStdout: 8388608, stderr: Platform.Process.Node.Managed.Capture 8388608, processTable: context.processTable }
        { cwd: "/", env, stdin: "" }
        context.node
        [ context.cucumber, "--config", context.support <> "/cucumber.json", "--parallel", "0", "--import", context.support <> "/steps.mjs", "--format", "progress", "--format", "json:" <> output <> "/cucumber.json", "--name", "^Start the native Phoenix package offline$", context.feature ]
      observed <- Data.Either.either (Effect.Aff.throwError <<< Effect.Aff.error <<< show) pure result
      Effect.Class.liftEffect do
        Platform.Node.Build.writeImpl (output <> "/stdout.txt") observed.stdout
        Platform.Node.Build.writeImpl (output <> "/stderr.txt") (Data.Maybe.fromMaybe "" observed.stderr)
      unless (observed.status == 0) do
        Effect.Class.liftEffect do
          Build.Output.writeLine Node.Process.stderr observed.stdout (pure unit)
          Build.Output.writeLine Node.Process.stderr (Data.Maybe.fromMaybe "" observed.stderr) (pure unit)
          Data.Foldable.traverse_
            ( \name -> do
                exists <- Platform.Node.Build.existsImpl (output <> "/" <> name)
                when exists do
                  receipt <- Platform.Node.Build.readImpl (output <> "/" <> name)
                  Build.Output.writeLine Node.Process.stderr (name <> ": " <> receipt) (pure unit)
            )
            [ "failure-progress.json", "progress.json", "cleanup.json", "journey.json" ]
        Effect.Aff.throwError (Effect.Aff.error "Package smoke failed; request/response and cleanup diagnostics retained in the build log")
      report <-
        Build.Json.read (output <> "/cucumber.json")
          :: Effect.Aff.Aff (Array { elements :: Array { name :: String, type :: String, steps :: Array { result :: { status :: String } } } })
      let
        selected = Data.Array.filter (\entry -> entry.type == "scenario") (Data.Array.concatMap _.elements report)
      unless (Data.Array.length selected == 1 && Data.Foldable.all (\entry -> entry.name == "Start the native Phoenix package offline" && not (Data.Array.null entry.steps) && Data.Foldable.all (\step -> step.result.status == "passed") entry.steps) selected)
        (Effect.Aff.throwError (Effect.Aff.error "Package smoke selected zero, multiple or incomplete scenarios"))
      finished <- Effect.Class.liftEffect Test.Deadline.now
      unless (finished - started < Data.Int.toNumber context.policy.singleMilliseconds) (Effect.Aff.throwError (Effect.Aff.error "Package smoke exceeded the shared deadline"))
      Build.Json.write (output <> "/receipt.json") { accepted: true, selected: 1, package: context.package, launcher: context.package <> "/bin/phoenix", elapsedMs: finished - started, limitMs: context.policy.singleMilliseconds, subprocessCleanupComplete: true, concurrency: 1, node: Node.Process.version }
    _ ->
      Effect.Aff.throwError (Effect.Aff.error "Package smoke requires output and context")
