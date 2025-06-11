#!/bin/bash

set -ex

cargo build --workspace

# export RUST_LOG="cosmian_cli=trace,cosmian_findex_server=trace"

echo "Running tests in an infinite loop"
while true; do
  reset
  echo "Iteration: $((++count))"
  cargo test --workspace -- --nocapture
  sleep 1
done
