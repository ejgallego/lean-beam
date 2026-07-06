/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Feedback
import BeamTest.Broker.JsonAssert

open Lean
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.FeedbackTest

private def homeFixture : IO String := do
  let home? ← IO.getEnv "HOME"
  pure <| home?.getD "/tmp/beam-feedback-home"

private def sampleInput (home : String) : Beam.Feedback.Input := {
  title := "Daemon startup failure"
  summary := s!"Beam failed while reading {home}/project/Demo.lean"
  reproduction := s!"cd {home}/project && lean-beam run-at Demo.lean 1 0"
  expected := "The request should return a structured Beam response."
  actual := "The daemon connection closed before a response was returned."
  tags := #["daemon", "feedback"]
  clientRequestId? := some "req-123"
  request? := some <| Json.mkObj [("path", toJson s!"{home}/project/Demo.lean")]
  response? := some <| Json.mkObj [("ok", toJson false)]
}

private def sampleCollection (home : String) : Beam.Feedback.Collection := {
  generatedAt := "2026-07-06T10:11:12Z"
  activeRoot? := some s!"{home}/project"
  data := Json.mkObj [
    ("identity", Json.mkObj [("beam_cli", toJson s!"{home}/beam-cli")]),
    ("stats", Json.mkObj [("requests", toJson (3 : Nat))]),
    ("openFiles", Json.arr #[Json.mkObj [("path", toJson s!"{home}/project/Demo.lean")]]),
    ("daemon", Json.mkObj [("recentDaemonIncidents", Json.arr #[])])
  ]
  warnings := #["fixture warning"]
}

private def checkRenderAndRedaction : IO Unit := do
  let home ← homeFixture
  let result ← Beam.Feedback.renderResult (sampleInput home) (sampleCollection home)
  require "report card title" (result.markdown.contains "# Daemon startup failure")
  require "report card summary section" (result.markdown.contains "## Summary")
  require "report card debug context section" (result.markdown.contains "## Beam Debug Context")
  require "report card should render collection warnings"
    (result.markdown.contains "Collection warnings:" && result.markdown.contains "fixture warning")
  requireJsonString "feedback metadata" "schema" "beam.feedback.report-card.v1" result.metadata
  requireJsonString "feedback metadata" "client_request_id" "req-123" result.metadata
  if !home.isEmpty then
    require "markdown should redact HOME" (!result.markdown.contains home)
    require "collected debug data should redact HOME" (!result.collected.compress.contains home)
    require "redacted report should still show a readable placeholder" (result.markdown.contains "~/project")

private def checkInputRoundTrip : IO Unit := do
  let home ← homeFixture
  let input : Beam.Feedback.Input := {
    sampleInput home with
      impact? := some "Blocks local proof repair."
      workaround? := some "Restart the daemon."
      evidence := #[
        { name := "trace.json", content? := some <| Json.mkObj [("path", toJson s!"{home}/trace")] },
        { name := "stderr.log", path? := some "stderr.log" }
      ]
      bundle := .zip
      redact := false
  }
  let json := toJson input
  requireJsonString "feedback input json" "client_request_id" "req-123" json
  requireJsonString "feedback input json" "bundle" "zip" json
  requireJsonBool "feedback input json" "redact" false json
  requireFieldAbsent "feedback input json" "clientRequestId" json
  let decoded ← expectOk "feedback input round-trip" <| fromJson? (α := Beam.Feedback.Input) json
  require "decoded feedback client request id" (decoded.clientRequestId? == some "req-123")
  require "decoded feedback evidence count" (decoded.evidence.size == 2)
  require "decoded feedback bundle" (decoded.bundle == .zip)
  require "decoded feedback redact" (!decoded.redact)
  let some firstEvidence := input.evidence[0]?
    | throw <| IO.userError "feedback input fixture missing first evidence"
  let evidenceJson := toJson firstEvidence
  requireJsonString "feedback evidence json" "name" "trace.json" evidenceJson
  requireFieldAbsent "feedback evidence json" "content?" evidenceJson

private def checkInputErrorMessages : IO Unit := do
  match fromJson? (α := Beam.Feedback.Input) Json.null with
  | .ok _ =>
      throw <| IO.userError "non-object feedback input decoded unexpectedly"
  | .error err =>
      require "non-object feedback input error should name JSON object requirement"
        (err.contains "feedback input must be a JSON object")

  match fromJson? (α := Beam.Feedback.Input) (Json.mkObj []) with
  | .ok _ =>
      throw <| IO.userError "empty feedback input decoded unexpectedly"
  | .error err =>
      require "empty feedback input error should name missing title"
        (err.contains "missing required string field 'title'")

  match fromJson? (α := Beam.Feedback.Input) <| Json.mkObj [
    ("title", toJson (3 : Nat))
  ] with
  | .ok _ =>
      throw <| IO.userError "wrong-type feedback title decoded unexpectedly"
  | .error err =>
      require "wrong-type feedback title error should name the field"
        (err.contains "field 'title' must be a string")

private def checkValidation : IO Unit := do
  match Beam.Feedback.validateEvidenceName "trace.log" with
  | .ok () => pure ()
  | .error err => throw <| IO.userError s!"valid evidence name rejected: {err}"
  match Beam.Feedback.validateEvidenceName "../trace.log" with
  | .ok () => throw <| IO.userError "path-like evidence name accepted unexpectedly"
  | .error err => require "path-like evidence name error" (err.contains "path separators")

private def checkBundleWrite : IO Unit := do
  let home ← homeFixture
  let root := System.FilePath.mk s!"/tmp/beam-feedback-test-{← IO.monoNanosNow}"
  IO.FS.createDirAll root
  IO.FS.writeFile (root / "trace.log") s!"raw trace from {home}/project\n"
  let input : Beam.Feedback.Input := {
    sampleInput home with
      bundle := .dir
      evidence := #[
        { name := "trace.log", path? := some "trace.log" },
        { name := "inline.json", content? := some <| Json.mkObj [("root", toJson s!"{home}/project")] }
      ]
  }
  let result ← Beam.Feedback.buildResult input (sampleCollection home) {
    root? := some root
    allowedRoots := #[root]
  }
  let some bundleDirText := result.bundleDir?
    | throw <| IO.userError "feedback bundle did not report bundle_dir"
  let bundleDir := System.FilePath.mk bundleDirText
  require "feedback bundle directory exists" (← bundleDir.pathExists)
  let card ← IO.FS.readFile (bundleDir / "card.md")
  require "bundle card contains report title" (card.contains "# Daemon startup failure")
  let metadataText ← IO.FS.readFile (bundleDir / "metadata.json")
  let metadata ← expectOk "parse feedback metadata bundle json" <| Json.parse metadataText
  requireJsonString "feedback bundle metadata" "schema" "beam.feedback.report-card.v1" metadata
  let collectedText ← IO.FS.readFile (bundleDir / "collected.json")
  let collected ← expectOk "parse feedback collected bundle json" <| Json.parse collectedText
  discard <| requireObjVal "feedback bundle collected" "daemon" collected
  let reportText ← IO.FS.readFile (bundleDir / "report.json")
  let report ← expectOk "parse feedback report bundle json" <| Json.parse reportText
  discard <| requireObjVal "feedback bundle report" "collected" report
  discard <| requireObjVal "feedback bundle report" "collection_warnings" report
  let trace ← IO.FS.readFile (bundleDir / "evidence" / "trace.log")
  if !home.isEmpty then
    require "file evidence should be redacted" (!trace.contains home)
  let inline ← IO.FS.readFile (bundleDir / "evidence" / "inline.json")
  require "inline evidence is written" (inline.contains "project")

private def checkZipBundleReportRoundTrip : IO Unit := do
  let home ← homeFixture
  let root := System.FilePath.mk s!"/tmp/beam-feedback-zip-test-{← IO.monoNanosNow}"
  IO.FS.createDirAll root
  let input : Beam.Feedback.Input := {
    sampleInput home with
      bundle := .zip
  }
  let result ← Beam.Feedback.buildResult input (sampleCollection home) {
    root? := some root
    allowedRoots := #[root]
  }
  let some bundleDirText := result.bundleDir?
    | throw <| IO.userError "feedback zip bundle did not report bundle_dir"
  let bundleDir := System.FilePath.mk bundleDirText
  let reportText ← IO.FS.readFile (bundleDir / "report.json")
  let report ← expectOk "parse feedback zip report bundle json" <| Json.parse reportText
  match result.zipPath? with
  | some zipPath =>
      requireJsonString "feedback zip bundle report" "zip_path" zipPath report
      require "feedback zip archive exists" (← (System.FilePath.mk zipPath).pathExists)
  | none =>
      requireFieldAbsent "feedback zip bundle report" "zip_path" report
      let warnings ← requireObjVal "feedback zip bundle report" "collection_warnings" report
      require "feedback zip warning is recorded in report"
        (warnings.compress.contains "zip")

def main : IO Unit := do
  checkRenderAndRedaction
  checkInputRoundTrip
  checkInputErrorMessages
  checkValidation
  checkBundleWrite
  checkZipBundleReportRoundTrip

end BeamTest.Broker.FeedbackTest

def main := BeamTest.Broker.FeedbackTest.main
