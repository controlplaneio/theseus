#!/usr/bin/env bash

load '_helper'

@test "has usage text" {
  run ${APP} --help
  assert_line --index 0 'Usage: theseus filename [options]'
}

@test "fails --tag without argument" {
  run ${APP} --tag
  assert_failure
}

@test "fails --weight without argument" {
  run ${APP} --weight
  assert_failure
}

@test "fails --precedence without argument" {
  run ${APP} --precedence
  assert_failure
}

@test "fails --name without argument" {
  run ${APP} --name
  assert_failure
}

@test "fails --header without argument" {
  run ${APP} --header
  assert_failure
}

@test "fails --regex without argument" {
  run ${APP} --regex
  assert_failure
}

@test "fails --test without argument" {
  run ${APP} --test
  assert_failure
}

@test "fails --regex [regex] without --header " {
  run ${APP} \
    ${DRY_RUN_DEFAULTS} \
    --regex test

  assert_failure
  assert_line --index 0 --regexp '--header required with --regex'
}

@test "passes --regex [test] with --header [cookie]" {
  run ${APP} \
    ${DRY_RUN_DEFAULTS} \
    --regex test \
    --header cookie

  assert_success
}

@test "passes --cookie [regex] without --header " {
  run ${APP} \
    ${DRY_RUN_DEFAULTS} \
    --cookie test

  assert_success
}


#@test "fails without argument AWS credentials" {
#  run ${APP} --dry-run --test base
#
#  assert_failure
#  assert_line --index 0 --regexp 'AWS_SECRET_ACCESS_KEY environment variable required.'
#}
#
#@test "passes --test with minimal env vars" {
#  AWS_SECRET_ACCESS_KEY=test \
#  AWS_ACCESS_KEY_ID=test \
#  BASE64_SSH_KEY=test \
#    run ${APP} --dry-run --test base
#
#  assert_success
#  assert_line --index 0 --regexp '^docker run .* rake spec --trace"$'
#}
#
#@test "passes --build with minimal env vars" {
#  AWS_SECRET_ACCESS_KEY=test \
#  AWS_ACCESS_KEY_ID=test \
#  BASE64_SSH_KEY=test \
#  BASE64_ANSIBLE_KEY=test \
#    run ${APP} --dry-run --build users_play.yml
#
#  assert_success
#  assert_line --index 0 --regexp '^docker run .* ansible-playbook .*users_play.yml".*$'
#}
#
#@test "notifies of ansible playbook name rewrite" {
#  AWS_SECRET_ACCESS_KEY=test \
#  AWS_ACCESS_KEY_ID=test \
#  BASE64_SSH_KEY=test \
#  BASE64_ANSIBLE_KEY=test \
#    run ${APP} --dry-run --build users
#
#  assert_success
#  assert_line --index 0 --regexp "Playbook name updated to 'users_play.yml'"
#}
#
#@test "does not notify if no ansible playbook name rewrite" {
#  AWS_SECRET_ACCESS_KEY=test \
#  AWS_ACCESS_KEY_ID=test \
#  BASE64_SSH_KEY=test \
#  BASE64_ANSIBLE_KEY=test \
#    run ${APP} --dry-run --build users_play.yml
#
#  assert_success
#  refute_line --index 0 --regexp "Playbook name updated to 'users_play.yml'"
#}
