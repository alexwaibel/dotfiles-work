#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

source "$(dirname "${BASH_SOURCE[0]}")/shell-test-helpers.sh"

expect_success "shell syntax" bash -n "$script"
expect_success "help" bash "$script" --help
expect_failure "missing command" bash "$script"
expect_failure "unknown command" bash "$script" unknown
expect_failure "invalid seed work item" bash "$script" --dry-run seed abc valid-slug repo
expect_failure "invalid slug" bash "$script" --dry-run seed 123 Invalid_Slug repo

finish_tests
