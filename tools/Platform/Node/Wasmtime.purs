module Platform.Node.Wasmtime where

import Prelude

import Data.Nullable as Data.Nullable
import Effect as Effect
import Node.Buffer as Node.Buffer

foreign import data Library :: Type
foreign import data Pointer :: Type

foreign import loadImpl :: String -> Effect.Effect Library
foreign import pointerImpl :: Node.Buffer.Buffer -> Effect.Effect (Data.Nullable.Nullable Pointer)
foreign import engineNewImpl :: Library -> Effect.Effect Pointer
foreign import engineDeleteImpl :: Library -> Pointer -> Effect.Effect Unit
foreign import moduleNewImpl :: Library -> Pointer -> Node.Buffer.Buffer -> Int -> Node.Buffer.Buffer -> Effect.Effect (Data.Nullable.Nullable Pointer)
foreign import moduleDeleteImpl :: Library -> Pointer -> Effect.Effect Unit
foreign import storeNewImpl :: Library -> Pointer -> Effect.Effect Pointer
foreign import storeDeleteImpl :: Library -> Pointer -> Effect.Effect Unit
foreign import contextImpl :: Library -> Pointer -> Effect.Effect Pointer
foreign import wasiNewImpl :: Library -> Effect.Effect Pointer
foreign import wasiArgvImpl :: Library -> Pointer -> Int -> Array String -> Effect.Effect Unit
foreign import wasiStdoutImpl :: Library -> Pointer -> String -> Effect.Effect Boolean
foreign import wasiStderrImpl :: Library -> Pointer -> String -> Effect.Effect Boolean
foreign import contextWasiImpl :: Library -> Pointer -> Pointer -> Effect.Effect (Data.Nullable.Nullable Pointer)
foreign import linkerNewImpl :: Library -> Pointer -> Effect.Effect Pointer
foreign import linkerDeleteImpl :: Library -> Pointer -> Effect.Effect Unit
foreign import linkerWasiImpl :: Library -> Pointer -> Effect.Effect (Data.Nullable.Nullable Pointer)
foreign import linkerModuleImpl :: Library -> Pointer -> Pointer -> String -> Int -> Pointer -> Effect.Effect (Data.Nullable.Nullable Pointer)
foreign import linkerDefaultImpl :: Library -> Pointer -> Pointer -> String -> Int -> Node.Buffer.Buffer -> Effect.Effect (Data.Nullable.Nullable Pointer)
foreign import callImpl :: Library -> Pointer -> Node.Buffer.Buffer -> Node.Buffer.Buffer -> Effect.Effect (Data.Nullable.Nullable Pointer)
