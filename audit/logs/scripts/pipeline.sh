#!/usr/bin/env bash
# Heavy jobs one after another (2 CPUs, 8 GB): wait for Halmos, then coverage, then mutation.
SP=/tmp/claude-0/-home-claude/c90d58fd-1930-5dd9-a7a1-c28eb862692d/scratchpad
while [ ! -f $SP/halmos-final.done ]; do sleep 20; done
echo "halmos done $(date)" >> $SP/pipeline.log
rm -rf /home/claude/coverage-run && mkdir -p /home/claude/coverage-run
cd /home/claude/spectrum && tar --exclude=./out --exclude=./cache --exclude=./lib --exclude=./.git --exclude=./out-halmos --exclude=./cache-halmos -cf - . | (cd /home/claude/coverage-run && tar xf -)
ln -s /home/claude/spectrum/lib /home/claude/coverage-run/lib
cd /home/claude/coverage-run
export PATH=/home/claude/tools/bin:$PATH FOUNDRY_SOLC=/home/claude/tools/bin/solc-0.8.26 FOUNDRY_OFFLINE=true
t0=$(date +%s)
forge coverage --ir-minimum --report summary --report lcov --no-match-coverage "test|script|lib" > $SP/coverage.log 2>&1
echo "coverage exit=$? seconds=$(( $(date +%s) - t0 )) $(date)" >> $SP/pipeline.log
$SP/run-mutation.sh
echo "mutation exit=$? $(date)" >> $SP/pipeline.log
echo PIPELINE-DONE >> $SP/pipeline.log
