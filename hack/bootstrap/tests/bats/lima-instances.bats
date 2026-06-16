#!/usr/bin/env bats
# shellcheck shell=bash

load '../helpers/common.bash'

setup() {
  LIMA_HOME="$BATS_TEST_TMPDIR/lima-home"
  LIMA_CLUSTER_NAME="testcluster"
  export LIMA_HOME LIMA_CLUSTER_NAME
  mkdir -p "$LIMA_HOME"
  # shellcheck source=hack/bootstrap/lima/lib.sh
  source "$ROOT/hack/bootstrap/lima/lib.sh"
}

@test "lima_instance_exists keys off the on-disk instance dir, not limactl list" {
  mkdir -p "$LIMA_HOME/testcluster-server-1"
  run lima_instance_exists testcluster-server-1
  assert_success
  run lima_instance_exists testcluster-server-2
  assert_failure
}

@test "lima_cluster_instance_names enumerates server/agent dirs and ignores others" {
  mkdir -p "$LIMA_HOME/testcluster-server-1" \
    "$LIMA_HOME/testcluster-agent-1" \
    "$LIMA_HOME/testcluster-agent-2" \
    "$LIMA_HOME/testcluster-server-x" \
    "$LIMA_HOME/othercluster-server-1" \
    "$LIMA_HOME/home-ops-rpi-image-builder"
  run lima_cluster_instance_names
  assert_success
  assert_output_contains "testcluster-server-1"
  assert_output_contains "testcluster-agent-1"
  assert_output_contains "testcluster-agent-2"
  assert_output_not_contains "testcluster-server-x"
  assert_output_not_contains "othercluster-server-1"
  assert_output_not_contains "home-ops-rpi-image-builder"
}

@test "lima_cluster_instance_names is empty when no matching instance dirs exist" {
  run lima_cluster_instance_names
  assert_success
  [[ -z "$output" ]]
}
