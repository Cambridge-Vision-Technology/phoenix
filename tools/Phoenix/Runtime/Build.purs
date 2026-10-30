module Phoenix.Runtime.Build (main) where

import Prelude

import Data.Array as Data.Array
import Effect as Effect
import Effect.Exception as Effect.Exception
import Node.Process as Node.Process
import Platform.Node.Build as Platform.Node.Build

main :: Effect.Effect Unit
main = do
  arguments <- Data.Array.drop 2 <$> Node.Process.argv
  case arguments of
    [ output, archive, unzip, install, patchelf, interpreter, libraries ] -> do
      cwd <- Node.Process.cwd
      Platform.Node.Build.executeImpl unzip [ archive ] cwd
      Platform.Node.Build.executeImpl install [ "-Dm755", "deno", output <> "/bin/deno" ] cwd
      Platform.Node.Build.executeImpl patchelf [ "--set-interpreter", interpreter, "--set-rpath", libraries, output <> "/bin/deno" ] cwd
    _ ->
      Effect.Exception.throw "Expected output, Deno archive, unzip, install, patchelf, interpreter and libraries"
