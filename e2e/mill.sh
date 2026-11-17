#!/usr/bin/env bash
#
# Copyright (c) 2026 - for information on the respective copyright owner
# see the NOTICE file and/or the repository https://github.com/carbynestack/carbynestack.
#
# SPDX-License-Identifier: Apache-2.0
#
# Millionaires' test: three games of billionaires.mpc through the Carbyne Stack CLI.
# Each game creates two secrets, executes the program on both players through
# Ephemeral, reads the result secret and deletes the inputs.
#
# Environment:
#   CLI_JAR      path of cli-<version>.jar         (default: $WORK/cli/cli-0.6.0.jar)
#   CLI_CONFIG   CLI configuration file            (default: $WORK/cli/config)
#   CLI_TOKENS   CLI access token file (cs login)  (default: $WORK/cli/tokens.json)
#   WORK         working directory                 (default: $HOME/build-tmp)
#   JAVA_TOOL_OPTIONS must point to the trust store holding the cluster certificates.
set -u
WORK=${WORK:-$HOME/build-tmp}
CLI_JAR=${CLI_JAR:-$WORK/cli/cli-0.6.0.jar}
CLI_CONFIG=${CLI_CONFIG:-$WORK/cli/config}
CLI_TOKENS=${CLI_TOKENS:-$WORK/cli/tokens.json}
PROGRAM=${PROGRAM:-$(dirname "$0")/billionaires.mpc}
CS=(java -jar "$CLI_JAR" --config-file "$CLI_CONFIG" --access-token-file "$CLI_TOKENS")
NOISE='Picked up\|StatusLogger\|^\s*at '
rc=0

secret() { # value tag
  "${CS[@]}" amphora create-secret "$1" -t billionaire="$2" -t accessPolicy=carbynestack.def \
    -t authorizedPrograms=ephemeral-generic 2>&1 | grep -v "$NOISE" | tail -n 1
}

game() { # first second expected
  local a b r v took start s
  a=$(secret "$1" A); b=$(secret "$2" B); start=$(date +%s)
  r=$(timeout 150 "${CS[@]}" ephemeral execute -t 120 -i "$a" -i "$b" ephemeral-generic.default < "$PROGRAM" 2>&1 \
    | grep -v "$NOISE" | tail -n 1 | sed 's/[][]//g')
  took=$(( $(date +%s) - start ))
  v=$("${CS[@]}" amphora get-secret "$r" 2>&1 | grep -v "$NOISE" | head -n 1 | tr -d '[]')
  if [ "$v" = "$3" ]; then s=PASS; else s=FAIL; rc=1; fi
  echo "$s: $1 < $2 -> got '$v' expected '$3' (${took}s, result $r)"
  "${CS[@]}" amphora delete-secrets "$a" "$b" >/dev/null 2>&1
}

game 177 151 0
game 177 179 1
game 151 151 0
exit $rc
