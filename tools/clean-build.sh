#!/bin/bash
# Remove output directories, sources cache, logs, etc.
rm -rf ./lfs-build ./output ./packages/sources.list ./packages/md5sums
echo "✅ Build artifacts cleaned."