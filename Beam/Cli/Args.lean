/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Client
import Beam.Path
import Beam.LSP.Todo

open Lean

namespace Beam.Cli

open Beam.Broker

structure CliOptions where
  explicitRoot? : Option System.FilePath := none
  requestedPort? : Option UInt16 := none
  requestedSocket? : Option System.FilePath := none
  args : List String := []

structure ParsedTextArg where
  text? : Option String := none
  source : String := "argv"

def parseNatArg (name value : String) : IO Nat := do
  let some n := value.toNat?
    | throw <| IO.userError s!"invalid {name} '{value}'"
  pure n

def joinTextArgs (args : List String) : Option String :=
  if args.isEmpty then none else some <| String.intercalate " " args

def hasSubstring (text needle : String) : Bool :=
  match text.splitOn needle with
  | [_] => false
  | _ => true

def textArgUsage (cmdHead : String) : String :=
  s!"usage: beam [--root PATH] [--socket PATH | --port N] {cmdHead} [--stdin | --text-file <path> | -- <text...> | <text...>]"

def textArgReadsStdin (args : List String) : Bool :=
  match args with
  | ["--stdin"] => true
  | _ => false

def parseTextArg (cmdHead : String) (args : List String) : IO ParsedTextArg := do
  match args with
  | [] => pure {}
  | ["--stdin"] =>
      pure { text? := some (← (← IO.getStdin).readToEnd), source := "stdin" }
  | ["--text-file", path] =>
      pure { text? := some (← IO.FS.readFile (System.FilePath.mk path)), source := s!"text-file:{path}" }
  | "--" :: rest =>
      pure { text? := joinTextArgs rest, source := "argv" }
  | "--stdin" :: _ =>
      throw <| IO.userError (textArgUsage cmdHead)
  | "--text-file" :: _ =>
      throw <| IO.userError (textArgUsage cmdHead)
  | _ =>
      pure { text? := joinTextArgs args, source := "argv" }

def parseJsonText (label text : String) : IO Json := do
  match Json.parse text with
  | .ok json => pure json
  | .error err => throw <| IO.userError s!"invalid {label}: {err}"

def parseJsonArg (label arg : String) : IO Json := do
  let raw ←
    if arg == "-" then
      (← IO.getStdin).readToEnd
    else
      pure arg
  parseJsonText label raw

def handleArgUsage (cmdHead : String) : String :=
  s!"usage: beam [--root PATH] [--socket PATH | --port N] {cmdHead} <handle-json|-|--handle-file <path>>"

def handleArgReadsStdin (args : List String) : Bool :=
  match args with
  | "-" :: _ => true
  | _ => false

private def extractHandleJson (json : Json) : Json :=
  match json.getObjVal? "handle" with
  | .ok handle => handle
  | .error _ =>
      match json.getObjVal? "result" with
      | .ok result =>
          match result.getObjVal? "handle" with
          | .ok handle => handle
          | .error _ => json
      | .error _ => json

def parseHandleText (raw : String) : IO Handle := do
  let json ← parseJsonText "handle json" raw
  match fromJson? (extractHandleJson json) with
  | .ok handle => pure handle
  | .error err =>
      throw <| IO.userError s!"invalid handle payload: {err}"

def parseHandleArg (arg : String) : IO Handle := do
  let raw ←
    if arg == "-" then
      (← IO.getStdin).readToEnd
    else
      pure arg
  parseHandleText raw

def parseHandleInput (cmdHead : String) (args : List String) : IO (Handle × List String) := do
  match args with
  | [] =>
      throw <| IO.userError (handleArgUsage cmdHead)
  | "--handle-file" :: path :: rest =>
      pure ((← parseHandleText (← IO.FS.readFile (System.FilePath.mk path))), rest)
  | "--handle-file" :: _ =>
      throw <| IO.userError (handleArgUsage cmdHead)
  | arg :: rest =>
      pure ((← parseHandleArg arg), rest)

def parseLeanSyncArgs (args : List String) : IO Bool := do
  match args with
  | [] => pure false
  | ["+full"] => pure true
  | _ => throw <| IO.userError "usage: beam [--root PATH] [--socket PATH | --port N] lean-sync <path> [+full]"

def parseLeanRefreshArgs (args : List String) : IO Bool := do
  match args with
  | [] => pure false
  | ["+full"] => pure true
  | _ => throw <| IO.userError "usage: beam [--root PATH] [--socket PATH | --port N] lean-refresh <path> [+full]"

def parseLeanSaveArgs (args : List String) : IO Bool := do
  match args with
  | [] => pure false
  | ["+full"] => pure true
  | _ => throw <| IO.userError "usage: beam [--root PATH] [--socket PATH | --port N] lean-save <path> [+full]"

def parseLeanCloseSaveArgs (args : List String) : IO Bool := do
  match args with
  | [] => pure false
  | ["+full"] => pure true
  | _ => throw <| IO.userError "usage: beam [--root PATH] [--socket PATH | --port N] lean-close-save <path> [+full]"

private def parseTodoKindArg (value : String) : IO Beam.LSP.Todo.TodoKind := do
  match fromJson? (α := Beam.LSP.Todo.TodoKind) (Json.str value) with
  | .ok kind => pure kind
  | .error err =>
      let allowed := String.intercalate ", " Beam.LSP.Todo.TodoKind.allKeys.toList
      throw <| IO.userError s!"invalid todo kind '{value}' (expected one of: {allowed}): {err}"

private def parseTodoSuggestArg (value : String) : IO Beam.LSP.Todo.TodoSuggestMode := do
  match fromJson? (α := Beam.LSP.Todo.TodoSuggestMode) (Json.str value) with
  | .ok mode => pure mode
  | .error err =>
      let allowed := String.intercalate ", " Beam.LSP.Todo.TodoSuggestMode.allKeys.toList
      throw <| IO.userError s!"invalid todo suggest mode '{value}' (expected one of: {allowed}): {err}"

def leanTodoUsage : String :=
  "usage: beam [--root PATH] [--socket PATH | --port N] lean-todo <path> <version> <startLine> <startCharacter> <endLine> <endCharacter> [--kind <kind> ...] [--suggest none|basic]"

def parseLeanTodoArgs (args : List String) :
    IO (Option (Array Beam.LSP.Todo.TodoKind) × Option Beam.LSP.Todo.TodoSuggestMode) := do
  let rec loop
      (args : List String)
      (kinds : Array Beam.LSP.Todo.TodoKind)
      (suggest? : Option Beam.LSP.Todo.TodoSuggestMode) :
      IO (Option (Array Beam.LSP.Todo.TodoKind) × Option Beam.LSP.Todo.TodoSuggestMode) := do
    match args with
    | [] =>
        pure (if kinds.isEmpty then none else some kinds, suggest?)
    | "--kind" :: kind :: rest =>
        loop rest (kinds.push (← parseTodoKindArg kind)) suggest?
    | "--kind" :: _ =>
        throw <| IO.userError leanTodoUsage
    | "--suggest" :: mode :: rest =>
        loop rest kinds (some (← parseTodoSuggestArg mode))
    | "--suggest" :: _ =>
        throw <| IO.userError leanTodoUsage
    | _ =>
        throw <| IO.userError leanTodoUsage
  loop args #[] none

def shellQuote (text : String) : String :=
  "'" ++ text.replace "'" "'\\''" ++ "'"

def parseEnvFlag (raw : String) : Bool :=
  let normalized := raw.trimAscii.toString.toLower
  !(normalized.isEmpty || normalized == "0" || normalized == "false" || normalized == "no")

def envFlag? (name : String) : IO (Option Bool) := do
  match ← IO.getEnv name with
  | some raw => pure <| some (parseEnvFlag raw)
  | none => pure none

partial def parseCliOptions (opts : CliOptions) : List String → IO CliOptions
  | [] => pure opts
  | "--root" :: root :: rest => do
      let root ← Beam.resolveExistingPath <| System.FilePath.mk root
      parseCliOptions { opts with explicitRoot? := some root } rest
  | "--port" :: port :: rest => do
      let port ← IO.ofExcept <| parsePortText "port" port
      parseCliOptions { opts with requestedPort? := some port } rest
  | "--socket" :: socketPath :: rest =>
      parseCliOptions { opts with requestedSocket? := some (System.FilePath.mk socketPath) } rest
  | arg :: rest =>
      parseCliOptions { opts with args := opts.args ++ [arg] } rest

end Beam.Cli
