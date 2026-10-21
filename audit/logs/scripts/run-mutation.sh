#!/usr/bin/env bash
# Runs every Gambit mutant against the core suites in /home/claude/mutation-run (a copy of the
# repository; the repository itself is never modified). One line per mutant in mutation-results.tsv.
set -u
SP=${SCRATCH:-/tmp}
export PATH=/home/claude/tools/bin:$PATH FOUNDRY_SOLC=/home/claude/tools/bin/solc-0.8.26 FOUNDRY_OFFLINE=true FOUNDRY_PROFILE=mutation
cd /home/claude/mutation-run
OUT=$SP/mutation-results.tsv
: > $OUT
current=""
restore() { if [ -n "$current" ]; then cp /home/claude/mutants/orig.bak "$current"; current=""; fi; }
trap 'restore; exit 1' INT TERM
start=$(date +%s)
# Two gas-target tests fail under the light compiler profile used here (they pass with the
# production optimizer settings), so they are excluded from every run, baseline included.
SKIP="test_record_worstCaseGasFitsHookBudget|test_entropy_gas"
forge test --no-match-test "$SKIP" > $SP/mut-logs/baseline.log 2>&1
rc=$?
echo -e "baseline\texit=$rc\t$(( $(date +%s) - start ))s" >> $OUT
if [ $rc -ne 0 ]; then echo "baseline failed; stopping" >> $OUT; exit 1; fi
for tag in policy stabilizer treasury token oracle; do
  for dir in $(ls -d /home/claude/mutants/$tag/mutants/* | sort -t/ -k7 -n); do
    id=$(basename $dir)
    while [ -f $SP/heavy.lock ]; do sleep 10; done   # paused while a main-repo compile runs
    rel=$(cd $dir && find . -name '*.sol' | head -1); rel=${rel#./}
    cp "/home/claude/mutation-run/$rel" /home/claude/mutants/orig.bak
    current="/home/claude/mutation-run/$rel"
    cp "$dir/$rel" "$current"
    t0=$(date +%s)
    timeout 1800 forge test --fail-fast --no-match-test "$SKIP" > $SP/mut-logs/$tag-$id.log 2>&1
    rc=$?
    restore
    secs=$(( $(date +%s) - t0 ))
    if grep -qE "Compiler run failed|Error \([0-9]+\)|CompilerError" $SP/mut-logs/$tag-$id.log; then status=INVALID; first=""
    elif [ $rc -eq 0 ]; then status=SURVIVED; first=""
    elif [ $rc -eq 124 ]; then status=TIMEOUT; first=""
    else status=KILLED; first=$(grep -m1 -oE "\[FAIL[^]]*\] [A-Za-z0-9_]+\(" $SP/mut-logs/$tag-$id.log | sed 's/($//')
    fi
    echo -e "$tag-$id\t$status\t${secs}s\t$first" >> $OUT
  done
done
echo ALLDONE >> $OUT
