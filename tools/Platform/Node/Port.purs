module Platform.Node.Port where

import Prelude

import Effect as Effect
import Effect.Exception as Effect.Exception
import Effect.Uncurried as Effect.Uncurried
import Data.Nullable as Data.Nullable

foreign import data Server :: Type

foreign import createImpl :: Effect.Effect Server
foreign import listenImpl :: Server -> { port :: Int, host :: String } -> Effect.Effect Unit -> Effect.Effect Unit
foreign import addressImpl :: Server -> Effect.Effect (Data.Nullable.Nullable { port :: Int })
foreign import closeImpl :: Server -> Effect.Effect Unit -> Effect.Effect Unit
foreign import errorImpl :: Server -> Effect.Uncurried.EffectFn1 Effect.Exception.Error Unit -> Effect.Effect Unit
