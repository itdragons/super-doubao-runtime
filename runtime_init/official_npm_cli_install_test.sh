#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

BIN_DIR="${TEST_ROOT}/bin"
COMMAND_LOG="${TEST_ROOT}/commands.log"
USER_LOG="${TEST_ROOT}/users.log"
STDOUT="${TEST_ROOT}/stdout.log"
STDERR="${TEST_ROOT}/stderr.log"
mkdir -p "${BIN_DIR}"

cat >"${BIN_DIR}/gosu" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$1" >>"${OFFICIAL_NPM_CLI_TEST_USER_LOG}"
shift
args=("$@")
for index in "${!args[@]}"; do
  if [ "${args[${index}]}" = "bash" ] && [ "${args[$((index + 1))]:-}" = "-lc" ]; then
    args[$((index + 1))]="-c"
    break
  fi
done
exec "${args[@]}"
EOF
chmod +x "${BIN_DIR}/gosu"

cat >"${BIN_DIR}/npm" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${OFFICIAL_NPM_CLI_TEST_COMMAND_LOG}"
if [[ "$*" == *"official-b@1"* ]]; then
  printf 'simulated failure\n' >&2
  exit 7
fi
EOF
chmod +x "${BIN_DIR}/npm"

CONFIG="$(python3 <<'PY'
import base64
import json

print(base64.b64encode(json.dumps({
    "enabled": True,
    "items": [
        {"name": "official-a", "command": "npm install -g official-a@1", "kind": "official"},
        {"name": "official-b", "command": "npm install -g official-b@1", "kind": "official"},
        {"name": "official-disabled", "command": "npm install -g official-disabled@1", "kind": "official", "enabled": False},
    ],
}).encode()).decode())
PY
)"

PATH="${BIN_DIR}:${PATH}" \
MCP_VM_OFFICIAL_NPM_CLI_INSTALL_CONFIG_B64="${CONFIG}" \
OFFICIAL_NPM_CLI_INSTALL_GOSU="${BIN_DIR}/gosu" \
OFFICIAL_NPM_CLI_TEST_COMMAND_LOG="${COMMAND_LOG}" \
OFFICIAL_NPM_CLI_TEST_USER_LOG="${USER_LOG}" \
bash "${SCRIPT_DIR}/official_npm_cli_install.sh" >"${STDOUT}" 2>"${STDERR}"

grep -q '\[official-npm-cli-install\] START official-a' "${STDOUT}"
grep -q '\[official-npm-cli-install\] START official-a timeout=15s' "${STDOUT}"
grep -Eq '\[official-npm-cli-install\] FINISH official-a status=0 duration_ms=[0-9]+' "${STDOUT}"
grep -Eq '\[official-npm-cli-install\] FINISH official-b status=7 duration_ms=[0-9]+' "${STDOUT}"
grep -q '\[official-npm-cli-install\] SUCCEEDED: official-a' "${STDOUT}"
grep -q '\[official-npm-cli-install\] FAILED: official-b' "${STDOUT}"
grep -q '^__RUNTIME_INIT_STATUS__=success$' "${STDOUT}"
grep -q 'OFFICIAL NPM CLI INSTALL FAILED.*official-b' "${STDERR}"
grep -q 'simulated failure' "${STDERR}"
grep -q '^install -g official-a@1$' "${COMMAND_LOG}"
grep -q '^install -g official-b@1$' "${COMMAND_LOG}"
test "$(wc -l <"${USER_LOG}" | tr -d ' ')" = "2"
test "$(sort -u "${USER_LOG}")" = "user"

: >"${COMMAND_LOG}"
PATH="${BIN_DIR}:${PATH}" \
OFFICIAL_NPM_CLI_TEST_COMMAND_LOG="${COMMAND_LOG}" \
bash "${SCRIPT_DIR}/official_npm_cli_install.sh" >"${STDOUT}" 2>"${STDERR}"

grep -q '\[official-npm-cli-install\] config absent; skip' "${STDOUT}"
grep -q '^__RUNTIME_INIT_STATUS__=success$' "${STDOUT}"
test ! -s "${COMMAND_LOG}"

# All items fail: summary must still be clean, no awk file-not-found noise,
# and the script must still finish successfully (best-effort).
ALL_FAIL_CONFIG="$(python3 <<'PY'
import base64
import json

print(base64.b64encode(json.dumps({
    "enabled": True,
    "items": [
        {"name": "official-b", "command": "npm install -g official-b@1", "kind": "official"},
    ],
}).encode()).decode())
PY
)"

: >"${COMMAND_LOG}"
PATH="${BIN_DIR}:${PATH}" \
MCP_VM_OFFICIAL_NPM_CLI_INSTALL_CONFIG_B64="${ALL_FAIL_CONFIG}" \
OFFICIAL_NPM_CLI_INSTALL_GOSU="${BIN_DIR}/gosu" \
OFFICIAL_NPM_CLI_TEST_COMMAND_LOG="${COMMAND_LOG}" \
OFFICIAL_NPM_CLI_TEST_USER_LOG="${USER_LOG}" \
bash "${SCRIPT_DIR}/official_npm_cli_install.sh" >"${STDOUT}" 2>"${STDERR}"

grep -q '\[official-npm-cli-install\] SUCCEEDED: none' "${STDOUT}"
grep -q '\[official-npm-cli-install\] FAILED: official-b' "${STDOUT}"
grep -q '^__RUNTIME_INIT_STATUS__=success$' "${STDOUT}"
if grep -qi 'awk:.*success.txt' "${STDERR}"; then
  echo "official npm cli installer leaked awk file-not-found error on all-fail path" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parallel execution: independent packages install concurrently to keep
# startup fast. A timeline-recording fake npm lets us confirm overlap while the
# earlier success/failure assertions confirm per-item failure isolation is kept.
# ---------------------------------------------------------------------------
TIMELINE="${TEST_ROOT}/timeline.log"
cat >"${BIN_DIR}/npm" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'start %s\n' "$*" >>"${OFFICIAL_NPM_CLI_TEST_TIMELINE}"
sleep 0.3
printf 'end %s\n' "$*" >>"${OFFICIAL_NPM_CLI_TEST_TIMELINE}"
EOF
chmod +x "${BIN_DIR}/npm"

PARALLEL_CONFIG="$(python3 <<'PY'
import base64, json
print(base64.b64encode(json.dumps({
    "enabled": True,
    "items": [
        {"name": "par-a", "command": "npm install -g par-a@1", "kind": "official"},
        {"name": "par-b", "command": "npm install -g par-b@1", "kind": "official"},
        {"name": "par-c", "command": "npm install -g par-c@1", "kind": "official"},
    ],
}).encode()).decode())
PY
)"

: >"${TIMELINE}"
PATH="${BIN_DIR}:${PATH}" \
MCP_VM_OFFICIAL_NPM_CLI_INSTALL_CONFIG_B64="${PARALLEL_CONFIG}" \
OFFICIAL_NPM_CLI_INSTALL_GOSU="${BIN_DIR}/gosu" \
OFFICIAL_NPM_CLI_TEST_COMMAND_LOG="${COMMAND_LOG}" \
OFFICIAL_NPM_CLI_TEST_USER_LOG="${USER_LOG}" \
OFFICIAL_NPM_CLI_TEST_TIMELINE="${TIMELINE}" \
bash "${SCRIPT_DIR}/official_npm_cli_install.sh" >"${STDOUT}" 2>"${STDERR}"

# All three must have actually run.
test "$(grep -c '^start' "${TIMELINE}")" = "3"
# Concurrency: at least two installs must overlap (a second start before the
# first end). Serial execution would never produce two consecutive starts.
if ! awk '
  /^start/ { running++; if (running >= 2) { found=1 } ; next }
  /^end/   { running-- }
  END { exit(found ? 0 : 1) }
' "${TIMELINE}"; then
  echo "official npm installs did not run in parallel (timeline: $(tr "\n" "|" <"${TIMELINE}"))" >&2
  exit 1
fi

# Configured max_parallelism must bound concurrent npm processes. With a
# limit of 2 and 3 items, the third install must not start before one of the
# first two finishes.
LIMITED_PARALLEL_CONFIG="$(python3 <<'PY'
import base64, json
print(base64.b64encode(json.dumps({
    "enabled": True,
    "item_timeout_seconds": 5,
    "max_parallelism": 2,
    "items": [
        {"name": "limit-a", "command": "npm install -g limit-a@1", "kind": "official"},
        {"name": "limit-b", "command": "npm install -g limit-b@1", "kind": "official"},
        {"name": "limit-c", "command": "npm install -g limit-c@1", "kind": "official"},
    ],
}).encode()).decode())
PY
)"

: >"${TIMELINE}"
PATH="${BIN_DIR}:${PATH}" \
MCP_VM_OFFICIAL_NPM_CLI_INSTALL_CONFIG_B64="${LIMITED_PARALLEL_CONFIG}" \
OFFICIAL_NPM_CLI_INSTALL_GOSU="${BIN_DIR}/gosu" \
OFFICIAL_NPM_CLI_TEST_COMMAND_LOG="${COMMAND_LOG}" \
OFFICIAL_NPM_CLI_TEST_USER_LOG="${USER_LOG}" \
OFFICIAL_NPM_CLI_TEST_TIMELINE="${TIMELINE}" \
bash "${SCRIPT_DIR}/official_npm_cli_install.sh" >"${STDOUT}" 2>"${STDERR}"

test "$(grep -c '^start' "${TIMELINE}")" = "3"
if ! awk '
  /^start/ { running++; if (running > 2) { too_many=1 } ; next }
  /^end/   { running-- }
  END { exit(too_many ? 1 : 0) }
' "${TIMELINE}"; then
  echo "official npm max_parallelism=2 was exceeded (timeline: $(tr "\n" "|" <"${TIMELINE}"))" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Per-item timeout: a slow CLI must be marked failed and skipped without
# delaying successful siblings beyond the configured per-item budget.
# ---------------------------------------------------------------------------
cat >"${BIN_DIR}/npm" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${OFFICIAL_NPM_CLI_TEST_COMMAND_LOG}"
if [[ "$*" == *"slow-cli@1"* ]]; then
  sleep 3
else
  sleep 0.1
fi
EOF
chmod +x "${BIN_DIR}/npm"

TIMEOUT_CONFIG="$(python3 <<'PY'
import base64, json
print(base64.b64encode(json.dumps({
    "enabled": True,
    "item_timeout_seconds": 1,
    "items": [
        {"name": "slow-cli", "command": "npm install -g slow-cli@1", "kind": "official"},
        {"name": "fast-cli", "command": "npm install -g fast-cli@1", "kind": "official"},
    ],
}).encode()).decode())
PY
)"

: >"${COMMAND_LOG}"
start_epoch="$(date +%s)"
PATH="${BIN_DIR}:${PATH}" \
MCP_VM_OFFICIAL_NPM_CLI_INSTALL_CONFIG_B64="${TIMEOUT_CONFIG}" \
OFFICIAL_NPM_CLI_INSTALL_GOSU="${BIN_DIR}/gosu" \
OFFICIAL_NPM_CLI_TEST_COMMAND_LOG="${COMMAND_LOG}" \
OFFICIAL_NPM_CLI_TEST_USER_LOG="${USER_LOG}" \
bash "${SCRIPT_DIR}/official_npm_cli_install.sh" >"${STDOUT}" 2>"${STDERR}"
elapsed=$(( $(date +%s) - start_epoch ))

grep -Eq '\[official-npm-cli-install\] FINISH slow-cli status=124 duration_ms=[0-9]+' "${STDOUT}"
grep -Eq '\[official-npm-cli-install\] FINISH fast-cli status=0 duration_ms=[0-9]+' "${STDOUT}"
grep -q '\[official-npm-cli-install\] SUCCEEDED: fast-cli' "${STDOUT}"
grep -q '\[official-npm-cli-install\] FAILED: slow-cli' "${STDOUT}"
grep -q 'timed out after 1s' "${STDERR}"
grep -q '^__RUNTIME_INIT_STATUS__=success$' "${STDOUT}"
if [ "${elapsed}" -ge 3 ]; then
  echo "official npm per-item timeout did not skip slow CLI quickly, elapsed=${elapsed}s" >&2
  exit 1
fi
