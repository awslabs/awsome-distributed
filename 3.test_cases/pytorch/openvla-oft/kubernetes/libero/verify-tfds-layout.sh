#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -euo pipefail

SUITE="${1:-${TASK_SUITE:?usage: verify-tfds-layout.sh <task_suite>|all}}"
ROOT="${LIBERO_DATA_ROOT:-/data/datasets/rlds}"

check_one() {
  local s="$1"
  local d="$ROOT/$s"
  if [[ ! -d "$d" ]]; then
    echo "FAIL: missing directory $d" >&2
    return 1
  fi
  # dataset_info.json lives under 1.0.0/
  if ! find "$d" -type f -name dataset_info.json | grep -q .; then
    echo "FAIL: no dataset_info.json under $d" >&2
    return 1
  fi
  # at least one shard file
  if ! find "$d" -type f -name '*.tfrecord-*' | grep -q .; then
    echo "FAIL: no *.tfrecord-* shards under $d" >&2
    return 1
  fi
  echo "OK: $d looks like a well-formed TFDS tree"
}

if [[ "$SUITE" == "all" ]]; then
  for s in libero_spatial_no_noops libero_object_no_noops libero_goal_no_noops libero_10_no_noops; do
    check_one "$s"
  done
else
  check_one "$SUITE"
fi
