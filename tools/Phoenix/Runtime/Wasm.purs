module Phoenix.Runtime.Wasm (main) where

import Prelude

import Data.Array as Data.Array
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Effect as Effect
import Effect.Aff as Effect.Aff
import Effect.Class as Effect.Class
import Effect.Exception as Effect.Exception
import Node.Buffer as Node.Buffer
import Node.FS.Sync as Node.FS.Sync
import Node.Process as Node.Process
import Platform.Node.Wasmtime as Platform.Node.Wasmtime

check :: String -> Data.Nullable.Nullable Platform.Node.Wasmtime.Pointer -> Effect.Effect Unit
check operation result = unless (Data.Maybe.isNothing (Data.Nullable.toMaybe result))
  (Effect.Exception.throw ("Wasmtime failed: " <> operation))

requirePointer :: Node.Buffer.Buffer -> Effect.Effect Platform.Node.Wasmtime.Pointer
requirePointer output = Platform.Node.Wasmtime.pointerImpl output >>=
  Data.Maybe.maybe
    (Effect.Exception.throw "Wasmtime returned a null module")
    pure <<< Data.Nullable.toMaybe

main :: Effect.Effect Unit
main = Effect.Aff.launchAff_ do
  arguments <- Effect.Class.liftEffect (Data.Array.drop 2 <$> Node.Process.argv)
  case arguments of
    [ library, binary, program, stdout, stderr ] -> do
      lib <- Effect.Class.liftEffect (Platform.Node.Wasmtime.loadImpl library)
      bytes <- Effect.Class.liftEffect (Node.FS.Sync.readFile binary)
      size <- Effect.Class.liftEffect (Node.Buffer.size bytes)
      moduleOutput <- Effect.Class.liftEffect (Node.Buffer.alloc 8)
      func <- Effect.Class.liftEffect (Node.Buffer.alloc 16)
      trap <- Effect.Class.liftEffect (Node.Buffer.alloc 8)
      Effect.Aff.bracket (Effect.Class.liftEffect (Platform.Node.Wasmtime.engineNewImpl lib)) (Effect.Class.liftEffect <<< Platform.Node.Wasmtime.engineDeleteImpl lib) \engine -> do
        Effect.Class.liftEffect (Platform.Node.Wasmtime.moduleNewImpl lib engine bytes size moduleOutput >>= check "compile module")
        compiled <- Effect.Class.liftEffect (requirePointer moduleOutput)
        Effect.Aff.finally (Effect.Class.liftEffect (Platform.Node.Wasmtime.moduleDeleteImpl lib compiled)) do
          Effect.Aff.bracket (Effect.Class.liftEffect (Platform.Node.Wasmtime.storeNewImpl lib engine)) (Effect.Class.liftEffect <<< Platform.Node.Wasmtime.storeDeleteImpl lib) \store -> do
            context <- Effect.Class.liftEffect (Platform.Node.Wasmtime.contextImpl lib store)
            Effect.Class.liftEffect do
              wasi <- Platform.Node.Wasmtime.wasiNewImpl lib
              Platform.Node.Wasmtime.wasiArgvImpl lib wasi 3 [ "python", "-c", program ]
              Platform.Node.Wasmtime.wasiStdoutImpl lib wasi stdout >>= flip unless (Effect.Exception.throw "WASI stdout file failed")
              Platform.Node.Wasmtime.wasiStderrImpl lib wasi stderr >>= flip unless (Effect.Exception.throw "WASI stderr file failed")
              Platform.Node.Wasmtime.contextWasiImpl lib context wasi >>= check "configure WASI"
            Effect.Aff.bracket (Effect.Class.liftEffect (Platform.Node.Wasmtime.linkerNewImpl lib engine)) (Effect.Class.liftEffect <<< Platform.Node.Wasmtime.linkerDeleteImpl lib) \linker -> Effect.Class.liftEffect do
              Platform.Node.Wasmtime.linkerWasiImpl lib linker >>= check "define WASI"
              Platform.Node.Wasmtime.linkerModuleImpl lib linker context "" 0 compiled >>= check "link module"
              Platform.Node.Wasmtime.linkerDefaultImpl lib linker context "" 0 func >>= check "resolve command"
              Platform.Node.Wasmtime.callImpl lib context func trap >>= check "execute command"
              Platform.Node.Wasmtime.pointerImpl trap >>= check "guest trap"
    _ ->
      Effect.Aff.throwError (Effect.Aff.error "Expected environment Wasmtime library, WASM binary, program, stdout and stderr")
