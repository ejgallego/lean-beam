#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

bash tests/test-broker-fast.sh
bash tests/test-broker-slow.sh
