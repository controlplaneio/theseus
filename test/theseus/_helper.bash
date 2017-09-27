#!/usr/bin/env bash

load '../bin/bats-support/load'
load '../bin/bats-assert/load'

APP="./../theseus"
DRY_RUN_DEFAULTS="test/theseus/asset/beefjerky-deployment-v1.yaml --dry-run"
