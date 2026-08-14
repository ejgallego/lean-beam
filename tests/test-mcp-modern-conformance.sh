#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

export BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-mcp-modern-conformance}"
export MCP_CONFORMANCE_PACKAGE="${MCP_CONFORMANCE_PACKAGE:-@modelcontextprotocol/conformance@0.2.0-alpha.9}"
export MCP_CONFORMANCE_PROTOCOL_VERSION="2026-07-28"
export MCP_CONFORMANCE_BRIDGE_ERA="modern"
export MCP_CONFORMANCE_SUITE="all"
export MCP_CONFORMANCE_SCENARIOS="${MCP_CONFORMANCE_SCENARIOS:-tools-list http-header-validation dns-rebinding-protection}"

exec bash tests/test-mcp-conformance.sh
