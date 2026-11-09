#!/usr/bin/env bash
# Inventario de divergencia live (v4.7.0) vs main, codigo no-test
set -euo pipefail
UP=${UP:-/home/user/audit/upstream-babylon}
cd "$UP"
echo "### tags/commits"
git rev-parse v4.7.0 main
echo
echo "### stat (sin tests)"
git diff --stat v4.7.0 main -- '*.go' ':(exclude)*_test.go'
echo
echo "### tests nuevos (mapa de fixes)"
git diff v4.7.0 main -- '*_test.go' | grep '^+func Test' | sed 's/^+func //;s/(t \*testing.T) {//'
echo
echo "### commits de main no contenidos en v4.7.0 (topologia)"
git rev-list --count v4.7.0..main; git rev-list --count main..v4.7.0
