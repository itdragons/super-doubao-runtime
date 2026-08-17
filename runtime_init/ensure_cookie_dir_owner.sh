#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Keep browser profile directories writable for the user process. The cookie
# mount may not be ready yet, so common.sh guards that path with health checks.
runtime_init_log "start ensure cookie and browser profile owner"
runtime_init_ensure_cookie_root

runtime_init_success "cookie dir owner ensured"
