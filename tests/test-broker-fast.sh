#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

lake build \
  RunAt:shared \
  runAt-cli \
  runAt-cli-daemon \
  runAt-cli-client \
  RunAtTest.Broker.StreamDedupTest \
  runAt-cli-daemon-smoke-test \
  runAt-cli-daemon-save-stream-test \
  runAt-cli-daemon-request-stream-test \
  runAt-cli-daemon-rocq-smoke-test \
  > /dev/null

.lake/build/bin/runAt-cli-daemon-smoke-test > /dev/null
.lake/build/bin/runAt-cli-daemon-save-stream-test > /dev/null
.lake/build/bin/runAt-cli-daemon-request-stream-test > /dev/null
