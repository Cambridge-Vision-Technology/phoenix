module Phoenix.Runtime.Check (main) where

import Prelude

import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Maybe as Data.Maybe
import Data.String as Data.String
import Data.Time.Duration as Data.Time.Duration
import Effect as Effect
import Effect.Aff as Effect.Aff
import Effect.Class as Effect.Class
import Foreign.Object as Foreign.Object
import Node.Process as Node.Process
import Platform.Node.Build as Platform.Node.Build
import Platform.Process.Node.Managed as Platform.Process.Node.Managed

main :: Effect.Effect Unit
main = Effect.Aff.launchAff_ do
  arguments <- Effect.Class.liftEffect (Data.Array.drop 2 <$> Node.Process.argv)
  started <- Effect.Class.liftEffect Node.Process.uptime
  cwd <- Effect.Class.liftEffect Node.Process.cwd
  case arguments of
    [ output, runtimes, environment, wasmRunner, library, originalDeno, originalMonty, sha256, processTable ] -> do
      let
        wasm = runtimes <> "/share/phoenix/python-3.12.0.wasm"
        env = Foreign.Object.fromHomogeneous
          { "PATH": runtimes <> "/bin", "HOME": cwd, "DENO_DIR": cwd <> "/deno-cache", "DENO_NO_UPDATE_CHECK": "1", "PHOENIX_WASM_BINARY_PATH": wasm }
        run label executable args = do
          now <- Effect.Class.liftEffect Node.Process.uptime
          let
            remaining = 58000.0 - (now - started) * 1000.0
          when (remaining <= 0.0) (Effect.Aff.throwError (Effect.Aff.error "Runtime check exceeded its deadline"))
          result <- Platform.Process.Node.Managed.run
            { timeout: Data.Time.Duration.Milliseconds remaining, maxStdout: 1048576, stderr: Platform.Process.Node.Managed.Capture 1048576, processTable }
            { cwd, env, stdin: "" }
            executable
            args
          observed <- Data.Either.either (\error -> Effect.Aff.throwError (Effect.Aff.error (label <> ": " <> show error))) pure result
          Effect.Class.liftEffect do
            Platform.Node.Build.writeImpl (output <> "/" <> label <> "-stdout.txt") observed.stdout
            Platform.Node.Build.writeImpl (output <> "/" <> label <> "-stderr.txt") (Data.Maybe.fromMaybe "" observed.stderr)
          unless (observed.status == 0) (Effect.Aff.throwError (Effect.Aff.error (label <> " exited " <> show observed.status <> ": " <> Data.Maybe.fromMaybe "" observed.stderr)))
          pure observed.stdout
        expect label expected actual = unless (expected == actual)
          (Effect.Aff.throwError (Effect.Aff.error (label <> " expected " <> show expected <> " but received " <> show actual)))
        hash label path = do
          text <- run label sha256 [ path ]
          Data.Maybe.maybe (Effect.Aff.throwError (Effect.Aff.error "Missing SHA256")) pure (Data.Array.head (Data.String.split (Data.String.Pattern " ") text))
      Effect.Class.liftEffect (Platform.Node.Build.mkdirImpl output)
      let
        wasmtimeVersion = "49.0.0"
      wasmtimeMetadata <- Effect.Class.liftEffect (Platform.Node.Build.readImpl (environment <> "/lib/python3.13/site-packages/wasmtime-" <> wasmtimeVersion <> ".dist-info/METADATA"))
      unless (Data.String.contains (Data.String.Pattern ("\nVersion: " <> wasmtimeVersion <> "\n")) wasmtimeMetadata)
        (Effect.Aff.throwError (Effect.Aff.error "Unexpected environment wasmtime version"))
      denoVersion <- run "deno-version" "deno" [ "--version" ]
      expect "Deno version" "deno 2.1.4 (stable, release, x86_64-unknown-linux-gnu)\nv8 13.0.245.12-rusty\ntypescript 5.6.2\n" denoVersion
      let
        denoProgram = "console.log(6 * 7);"
        pythonProgram = "print(6 * 7)"
      Effect.Class.liftEffect (Platform.Node.Build.writeImpl (cwd <> "/runtime.js") denoProgram)
      denoOutput <- run "deno-program" "deno" [ "run", "--no-prompt", "--no-config", "--no-remote", "--no-npm", cwd <> "/runtime.js" ]
      expect "Deno program" "42\n" denoOutput
      montyVersion <- run "monty-version" "monty" [ "--version" ]
      expect "Monty version" "monty-runtime 1.1.0\n" montyVersion
      montyOutput <- run "monty-program" "monty" [ "-c", pythonProgram ]
      expect "Monty program" "42\n" montyOutput
      void (run "wasmtime-runner" wasmRunner [ library, wasm, pythonProgram, output <> "/wasm-stdout.txt", output <> "/wasm-stderr.txt" ])
      wasmOutput <- Effect.Class.liftEffect (Platform.Node.Build.readImpl (output <> "/wasm-stdout.txt"))
      expect "WASM program" "42\n" wasmOutput
      wasmError <- Effect.Class.liftEffect (Platform.Node.Build.readImpl (output <> "/wasm-stderr.txt"))
      expect "WASM stderr" "" wasmError
      wasmHash <- hash "wasm-hash" wasm
      expect "WASM hash" "e5dc5a398b07b54ea8fdb503bf68fb583d533f10ec3f930963e02b9505f7a763" wasmHash
      denoOriginalHash <- hash "deno-original-hash" originalDeno
      expect "Deno original hash" "10af0f31dc48bfea949e83daa042c03a9a84f7c52056d20597cac7ad005ab6aa" denoOriginalHash
      montyOriginalHash <- hash "monty-original-hash" originalMonty
      expect "Monty original hash" "c9d19e7256886558c67678582d0d223de3eb05232f69da9da657ab9e090f3f35" montyOriginalHash
      denoFixedHash <- hash "deno-fixed-hash" (runtimes <> "/bin/deno")
      montyFixedHash <- hash "monty-fixed-hash" (runtimes <> "/bin/monty")
      wasmtimeHash <- hash "wasmtime-hash" library
      finished <- Effect.Class.liftEffect Node.Process.uptime
      unless (finished - started < 60.0) (Effect.Aff.throwError (Effect.Aff.error "Runtime check exceeded 60 seconds"))
      Effect.Class.liftEffect
        ( Platform.Node.Build.writeImpl (output <> "/receipt.json")
            ( Data.Argonaut.Core.stringifyWithIndent 2
                ( Data.Argonaut.Encode.encodeJson
                    { environment, runtimes, library, wasmtimeVersion, denoVersion, montyVersion, denoProgram, pythonProgram, denoOutput, montyOutput, wasmOutput, wasmHash, denoOriginalHash, denoFixedHash, montyOriginalHash, montyFixedHash, wasmtimeHash, elapsedSeconds: finished - started, limitSeconds: 60, concurrency: 1, node: Node.Process.version, network: "Nix sandbox; no WASI network or preopens; Deno --no-remote --no-npm and default-deny permissions" }
                ) <> "\n"
            )
        )
    _ ->
      Effect.Aff.throwError (Effect.Aff.error "Expected output, runtimes, environment, wasmRunner, library, original Deno/Monty, sha256 and process table tool")
