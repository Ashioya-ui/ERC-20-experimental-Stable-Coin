#!/usr/bin/env bash
# Coverage of src/ from the suites that do not need v4-core's PoolManager (the full project's
# coverage build runs out of memory on this 8 GB machine). Hook coverage comes from the
# hook suites, which this run does not include.
set -u
SP=${SCRATCH:-/tmp}
R=/home/claude/coverage-lite
rm -rf $R && mkdir -p $R/test
cd /home/claude/spectrum
cp -r src foundry.toml remappings.txt $R/
mkdir -p $R/script/lib && cp script/lib/SpectrumDeploy.sol script/lib/TestnetVault.sol $R/script/lib/
cp -r test/utils test/mocks test/handlers test/reference test/paper test/artifacts $R/test/
cp test/SpectrumProtocol.t.sol test/LossFrontRunning.t.sol test/ProtocolCapital.t.sol test/ReviewFindings.t.sol $R/test/
ln -sfn /home/claude/spectrum/lib $R/lib
cd $R
export PATH=/home/claude/tools/bin:$PATH FOUNDRY_SOLC=/home/claude/tools/bin/solc-0.8.26 FOUNDRY_OFFLINE=true
forge coverage --ir-minimum --report summary --no-match-coverage "test|script|lib" > $SP/coverage-lite.log 2>&1
echo "exit=$?" >> $SP/coverage-lite.log
