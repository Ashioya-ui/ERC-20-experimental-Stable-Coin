#!/usr/bin/env bash
# usage: run-halmos3.sh <tag> then lines "<solver> <contract> <match-test regex>" on stdin-like args
cd /home/claude/halmos-run
SP=${SCRATCH:-/tmp}
export PATH=/home/claude/tools/bin:$PATH FOUNDRY_SOLC=/home/claude/tools/bin/solc-0.8.26 FOUNDRY_OFFLINE=true HALMOS_ALLOW_DOWNLOAD=1
run() { # solver contract regex name
  start=$(date +%s)
  halmos --contract $2 --match-test "$3" --loop 9 --solver $1 --solver-timeout-assertion 10m > $SP/halmos-final-$4.txt 2>&1
  echo "$4 solver=$1 exit=$? seconds=$(( $(date +%s) - start ))" >> $SP/halmos-final-summary.txt
}
rm -f $SP/halmos-final-summary.txt
run cvc5-int HalmosPolicy '^check_(buffer|churn|curves|expansion|monotone|rebaseStepBounded|rebaseStepLocally)' policy-cvc5
run bitwuzla-abs HalmosPolicy '^check_(mintFee|redeemFee|rebaseStepBelow)' policy-bitwuzla
run bitwuzla-abs HalmosFwht '^check_' fwht-bitwuzla
run bitwuzla-abs HalmosToken '^check_' token-bitwuzla
echo ALLDONE >> $SP/halmos-final-summary.txt
