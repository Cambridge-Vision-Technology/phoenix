module Platform.Node.Exec where

import Prelude

import Effect as Effect
import Foreign.Object as Foreign.Object

foreign import execveImpl :: String -> Array String -> Foreign.Object.Object String -> Effect.Effect Unit
