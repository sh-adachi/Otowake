#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
action="${1:-build}"
if (( $# > 0 )); then shift; fi
exec swift "$action" --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security "$@"
