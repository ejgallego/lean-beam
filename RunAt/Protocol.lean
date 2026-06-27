/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace RunAt

/--
JSON-RPC method name for the standalone `runAt` request.

This is the only public entry point. Backend selection remains internal:

- proof/tactic execution when a proof basis can be recovered at the given position
- command execution otherwise
-/
def method : String := "$/lean/runAt"

/-- JSON-RPC method name for follow-up execution from a stored handle. -/
def runWithMethod : String := "$/lean/runWith"

/-- JSON-RPC method name for explicit follow-up handle release. -/
def releaseHandleMethod : String := "$/lean/releaseHandle"

/-- JSON-RPC method name for read-only goal inspection after the position. -/
def goalsAfterMethod : String := "$/lean/goalsAfter"

/-- JSON-RPC method name for read-only goal inspection before the position. -/
def goalsPrevMethod : String := "$/lean/goalsPrev"

/-- JSON-RPC method name for agent-oriented todo inspection over a document range. -/
def todoMethod : String := "$/lean/todo"

/-- Opaque follow-up handle returned by the server. -/
structure Handle where
  value : String
  deriving FromJson, ToJson

/--
Public request payload for `$/lean/runAt`.

Current frozen request semantics:

- the request is identified only by `textDocument`, `position`, and `text`
- callers do not choose command vs tactic mode
- command-mode `text` is one Lean command, not a top-level command sequence
- proof-mode `text` is one tactic block
- `position` uses Lean/LSP `Position` semantics against the current open document version
- positions outside the document are invalid request parameters
- request-level failures are reported as transport errors rather than as `Result`
-/
structure Params where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  position : Lean.Lsp.Position
  text : String
  storeHandle? : Option Bool := none
  deriving FromJson, ToJson

-- Lean v4.28 compatibility shim: `Lean.Lsp.FileSource.fileSource` returns `FileIdent` there, but
-- newer Lean versions use `DocumentUri`. When we drop v4.28 support, re-check whether these request
-- types should switch back to the more direct `p.textDocument.uri` style used by newer upstream APIs.
instance : Lean.Lsp.FileSource Params where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Request payload for read-only goal inspection at a file position. -/
structure GoalsParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  position : Lean.Lsp.Position
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource GoalsParams where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Kinds of agent-actionable todo items reported by `$/lean/todo`. -/
inductive TodoKind where
  | sorry
  | hole
  | diagnostic
  | codeAction
  | incompleteProof
  deriving BEq, Repr

def TodoKind.key : TodoKind → String
  | .sorry => "sorry"
  | .hole => "hole"
  | .diagnostic => "diagnostic"
  | .codeAction => "code_action"
  | .incompleteProof => "incomplete_proof"

def TodoKind.all : Array TodoKind :=
  #[.sorry, .hole, .diagnostic, .codeAction, .incompleteProof]

def TodoKind.allKeys : Array String :=
  TodoKind.all.map TodoKind.key

instance : ToJson TodoKind where
  toJson kind := toJson kind.key

instance : FromJson TodoKind where
  fromJson?
    | .str "sorry" => .ok .sorry
    | .str "hole" => .ok .hole
    | .str "diagnostic" => .ok .diagnostic
    | .str "code_action" => .ok .codeAction
    | .str "incomplete_proof" => .ok .incompleteProof
    | j => .error s!"expected todo kind, got {j.compress}"

/-- Suggestion budget for `$/lean/todo`. -/
inductive TodoSuggestMode where
  | none
  | basic
  deriving BEq, Repr

def TodoSuggestMode.key : TodoSuggestMode → String
  | .none => "none"
  | .basic => "basic"

def TodoSuggestMode.all : Array TodoSuggestMode :=
  #[.none, .basic]

def TodoSuggestMode.allKeys : Array String :=
  TodoSuggestMode.all.map TodoSuggestMode.key

instance : ToJson TodoSuggestMode where
  toJson mode := toJson mode.key

instance : FromJson TodoSuggestMode where
  fromJson?
    | .str "none" => .ok .none
    | .str "basic" => .ok .basic
    | j => .error s!"expected todo suggest mode 'none' or 'basic', got {j.compress}"

/-- Request payload for agent-oriented todo inspection over a document range. -/
structure TodoParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  range : Lean.Lsp.Range
  kinds? : Option (Array TodoKind) := none
  suggest? : Option TodoSuggestMode := none
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource TodoParams where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Request payload for `$/lean/runWith`. -/
structure RunWithParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  handle : Handle
  text : String
  storeHandle? : Option Bool := none
  linear? : Option Bool := none
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource RunWithParams where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Request payload for `$/lean/releaseHandle`. -/
structure ReleaseHandleParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  handle : Handle
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource ReleaseHandleParams where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- A user-visible message emitted by isolated execution. -/
structure Message where
  severity : Lean.MessageSeverity
  text : String
  deriving FromJson, ToJson

/--
One hypothesis bundle in a structured proof goal.

Multiple names may share the same type when Lean groups hypotheses for display.
-/
structure GoalHyp where
  names : Array String := #[]
  type : String
  value? : Option String := none
  deriving FromJson, ToJson

/--
One structured proof goal.

This is a compact, stable projection of Lean's interactive goal representation.
-/
structure Goal where
  userName? : Option String := none
  goalPrefix : String := "⊢ "
  target : String
  hyps : Array GoalHyp := #[]
  deriving FromJson, ToJson

/--
Proof-state payload for proof-oriented execution.

This is only present when `runAt` executes against a recovered proof basis.
Command-mode execution does not invent a proof state.
Solved proof states use `goals := #[]`.
-/
structure ProofState where
  goals : Array Goal := #[]
  deriving FromJson, ToJson

/-- One normalized agent-facing todo item. -/
structure TodoItem where
  kind : TodoKind
  range : Lean.Lsp.Range
  runAtPosition : Lean.Lsp.Position
  runAtText? : Option String := none
  message? : Option String := none
  severity? : Option Lean.Lsp.DiagnosticSeverity := none
  diagnostic? : Option Lean.Lsp.Diagnostic := none
  codeAction? : Option Lean.Lsp.CodeAction := none
  proofState? : Option ProofState := none
  deriving FromJson, ToJson

/-- Typed success payload for `$/lean/todo`. -/
structure TodoResult where
  version : Nat
  range : Lean.Lsp.Range
  items : Array TodoItem := #[]
  deriving FromJson, ToJson

/--
Typed success payload for `$/lean/runAt`.

Current frozen response semantics:

- request-level failures are not encoded here; they are transport errors
- `success = true` iff execution completes without any error-severity messages
- semantic Lean failures stay in this payload through `messages`
- command-mode top-level command sequences fail here with a `runAtSupportsOneCommandOnly` message
- no backend tag is exposed in the public payload
- no extra status enum is exposed beyond `success`
- `handle?` is present only when the request asked the server to retain follow-up state
- `proofState?` is present only for proof-oriented execution
- proof goals are structured into target, hypotheses, and optional case name
- solved proof states use `proofState.goals = #[]`
- `traces` stays as a plain array; empty traces are represented as `#[]`
- positions outside the document produce transport `invalidParams`
- in-document positions with no usable command/proof snapshot may also produce transport `invalidParams`
- in-document whitespace/comment positions may still resolve to a nearby execution basis
- editing a document while a request is pending may produce transport `contentModified`
- stale pending requests may produce transport `contentModified`
- explicit cancellation may produce transport `requestCancelled`
- cancellation is cooperative inside isolated execution; prompt `requestCancelled` depends on inner
  elaboration polling Lean interruption
-/
structure Result where
  success : Bool := true
  messages : Array Message := #[]
  traces : Array String := #[]
  handle? : Option Handle := none
  proofState? : Option ProofState := none
  deriving FromJson, ToJson

end RunAt
