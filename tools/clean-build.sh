#!/bin/bash
set -euo pipefail

# Remove output directories, sources cache, logs, etc.
rm -rf ./lfs-build ./output ./htmlcov ./coverage.xml ./.coverage
echo "Build artifacts cleaned."