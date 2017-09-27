#!/usr/bin/env bash

load '_helper'

@test "errors on backup target starting with '-'" {

  run "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --cookie user=jason \
    --test "true" \
    --backup --delete

  assert_failure
  assert_line --index 0 --regexp "Invalid backup target: '--delete'"
}

@test "backs up rule via --backup" {

  \rm ~/.config/theseus/reviews-v1.yaml || true

  run timeout 500 "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --cookie user=jason \
    --test "true" \
    --backup 'reviews-v1' \
    --debug

  assert [ -d ~/.config/theseus ]
  assert [ -f ~/.config/theseus/reviews-v1.yaml ]
}

@test "errors if --backup target already exists" {

  \rm ~/.config/theseus/reviews-v1.yaml || true

  timeout 500 "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --cookie user=jason \
    --test "true" \
    --backup 'reviews-v1'

  run "${APP}" \
    test/theseus/asset/reviews-deployment-v2.yaml \
    --dry-run \
    --cookie user=jason \
    --test "true" \
    --backup 'reviews-v1'

  assert_failure
  assert_line --regexp "File '[^']*' already exists"
  assert [ -f ~/.config/theseus/reviews-v1.yaml ]
}

