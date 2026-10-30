module Phoenix.Python.Inputs.Json where

type Config = { packages :: Array String, excluded :: Array String, artifacts :: Array String, backend :: String, onlyPackages :: Boolean, version :: String, readme :: String, licenses :: Array String, entries :: Array String, wheelKeys :: Array String, buildKeys :: Array String }
type Edge = { from :: String, request :: String, target :: String }
type Graph = { inventory :: Array String, packageFiles :: Array String, modules :: Array String, artifacts :: Array String, artifactRoots :: Array String, edges :: Array Edge, entries :: Array String }
