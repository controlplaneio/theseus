#!/usr/bin/env bash

load '_helper'

source "${APP}"

# assert
# refute
# assert_equal
# assert_success
# assert_failure
# assert_output
# refute_output
# assert_line
# refute_line

@test "identifies when sourced" {
    assert is_sourced
}

@test "fails on empty filename" {
    run get_name_from_resource ""
    assert_failure
}

@test "identifies multi-document" {
    # prefixed with test? Diff between `make` and `test/test-theseus.sh`
    run is_multi_document_resource "theseus/asset/multi-document.yaml"
    assert_success
}

@test "identifies single-document" {
    # prefixed with test? Diff between `make` and `test/test-theseus.sh`
    run is_multi_document_resource "theseus/asset/reviews-deployment-v1.yaml"
    assert_failure
}

@test "parses deployment name from single document" {
    run get_name_from_resource "theseus/asset/reviews-deployment-v1.yaml"

#    echo "$output"
    assert_line \
      --index $(($(echo "$output" | wc -l) - 1)) \
      'reviews-v1'

    assert_success
}

@test "parses deployment name from multi-document" {
    run get_name_from_resource "theseus/asset/multi-document.yaml"

#    echo "$output"
    assert_line \
      --index $(($(echo "$output" | wc -l) - 1)) \
      'ghost-v1'

    assert_success
}

@test "errors with multiple deploys in multi-document" {
    run get_name_from_resource "theseus/asset/multi-document-duplicate.yaml"

#    echo "$output"
    assert_line \
      --index $(($(echo "$output" | wc -l) - 1)) \
      --regexp 'Ambiguous document: must provide exactly 1 Deployments, 2 found'

    assert_failure
}


@test "deletes contents of multi-document" {
#    run get_name_from_resource "theseus/asset/multi-document-duplicate.yaml"
#
##    echo "$output"
#    assert_line \
#      --index $(($(echo "$output" | wc -l) - 1)) \
#      --regexp 'Ambiguous document: must provide exactly 1 Deployments, 2 found'
#
#    assert_failure
}


@test "errors when deleting a deployment that's not deployed" {}
