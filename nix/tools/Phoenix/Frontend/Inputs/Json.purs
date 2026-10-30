module Phoenix.Frontend.Inputs.Json where

import Foreign.Object as Foreign.Object

type Inventory = { dependencies :: Array String, sources :: Array String }
type Recipe = { manifest :: String, scripts :: Foreign.Object.Object String, configs :: Array String }
type Generator = { manifest :: String, script :: String, input :: String, output :: String }
type Assets = { publicFiles :: Array String, moduleFiles :: Array String, generators :: Array Generator, recipes :: Array Recipe }
type Workspace = { name :: String, path :: String }
type Edge = { from :: String, request :: String, target :: String }
type ComputedAsset = { from :: String, expression :: String, request :: String, target :: String, form :: String }
type Graph = { inventory :: Inventory, workspaces :: Array Workspace, edges :: Array Edge, configs :: Array String, roots :: Array String, publicDirectory :: String, publicFiles :: Array String, moduleAssets :: Array String, computedAssets :: Array ComputedAsset, generators :: Array Generator }
