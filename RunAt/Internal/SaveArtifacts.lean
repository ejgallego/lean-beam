import Lean

open Lean

namespace RunAt.Internal

/--
Internal broker-only request for saving the current elaborated document state to
the Lake artifact locations expected by the workspace.

This is not part of the public `runAt` API.
-/
def saveArtifactsMethod : String := "$/lean/runAt/saveArtifacts"

/-- Internal request payload for artifact serialization from the current worker snapshot. -/
structure SaveArtifactsParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  oleanFile : String
  ileanFile : String
  cFile : String
  bcFile? : Option String := none
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource SaveArtifactsParams where
  fileSource p := p.textDocument.uri

/-- Internal success payload for artifact serialization. -/
structure SaveArtifactsResult where
  written : Bool := true
  version : Nat
  textHash : UInt64
  deriving FromJson, ToJson

end RunAt.Internal
