#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/scripts/lib/output.sh"
}

@test "ok() prints a pass marker and keeps FAIL_COUNT at zero" {
  run bash -c "source '$REPO_ROOT/scripts/lib/output.sh'; ok 'port terbuka'; echo \"count=\$FAIL_COUNT\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"port terbuka"* ]]
  [[ "$output" == *"count=0"* ]]
}

@test "fail() increments FAIL_COUNT but does not abort the script" {
  run bash -c "source '$REPO_ROOT/scripts/lib/output.sh'; fail 'port tertutup'; echo 'masih jalan'; echo \"count=\$FAIL_COUNT\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"masih jalan"* ]]
  [[ "$output" == *"count=1"* ]]
}

@test "summary() exits non-zero when there was a failure" {
  run bash -c "source '$REPO_ROOT/scripts/lib/output.sh'; fail 'x'; summary"
  [ "$status" -eq 1 ]
}

@test "summary() exits zero when everything passed" {
  run bash -c "source '$REPO_ROOT/scripts/lib/output.sh'; ok 'x'; summary"
  [ "$status" -eq 0 ]
}
