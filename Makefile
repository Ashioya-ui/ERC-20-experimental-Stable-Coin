# Spectrum Protocol: build, test, rehearse and deploy.
#
# Mainnet sequence (see RUNBOOK_MAINNET.md):
#   make test test-isolate rehearsal     # everything local, no keys
#   make bench                           # gas benchmarks (committed in .gas-snapshot)
#   make deploy-base-sepolia             # dress rehearsal on Base Sepolia (BASE_SEPOLIA_RPC_URL)
#   make fork-test                       # same scenarios on a Base mainnet fork (BASE_RPC_URL)
#   make preflight                       # full deployment simulated against live Base state
#   make deploy-base-mainnet             # broadcast + verify (Ledger by default)
#   make post-deploy-check               # read-only checks against the live deployment
#   make verify-base-mainnet             # re-verify with explicit constructor args if needed
#
# x402 rail (docs/design/x402-rail.md):
#   make x402                            # local chain, pay router, facilitator, merchant, demo, tests
#   make x402-serve                      # same set-up, then keeps serving for agents
#
# Audit tooling (audit/README.md):
#   make deps analyze formal coverage sim  # pins, Slither, Halmos, coverage, parameter model
#
# Settings come from the environment or a .env file (see .env.example).

SHELL := /bin/bash

-include .env
export

SIGNER   ?= --ledger
CHAIN_ID ?= 8453

.PHONY: help build test test-ci test-isolate bench snapshot rehearsal fork-test preflight \
        deploy-base-mainnet verify-base-mainnet verify-blockscout post-deploy-check sizes \
        clean-local analyze formal coverage deps sim preflight-sepolia deploy-base-sepolia \
        post-deploy-check-sepolia x402 x402-serve

help:
	@grep -E '^#' Makefile | sed 's/^# \{0,1\}//'

build:
	forge build --sizes

test:
	forge test

test-ci:
	FOUNDRY_PROFILE=ci forge test

test-isolate:
	forge test --isolate

bench:
	forge test --match-contract BenchmarksTest -vv

snapshot:
	forge snapshot --no-match-contract "Invariant|BaseMainnetFork"

sizes:
	forge build --sizes | grep -E "Spectral|Autonomous|Wrapped"

rehearsal:
	script/rehearsal/run.sh

x402:
	script/rehearsal/x402.sh

x402-serve:
	script/rehearsal/x402.sh --serve

deps:
	script/check-deps.sh

analyze:
	slither . --filter-paths "lib/|test/|script/" --exclude-dependencies \
	  --triage-database audit/slither.db.json --fail-medium

# Each check runs with the solver that finishes it (audit/formal.md). Halmos fetches the solvers
# from their GitHub releases and checks the sha256 it pins; HALMOS_ALLOW_DOWNLOAD allows that.
# Two fee-monotonicity checks reach the solver time limit, so a failure does not stop make.
HALMOS = HALMOS_ALLOW_DOWNLOAD=1 FOUNDRY_OUT=out-halmos FOUNDRY_CACHE_PATH=cache-halmos \
         halmos --forge-build-out out-halmos --loop 9 --solver-timeout-assertion 10m

formal:
	-$(HALMOS) --contract HalmosPolicy --solver cvc5-int \
	  --match-test '^check_(buffer|churn|curves|expansion|monotone|rebaseStepBounded|rebaseStepLocally)'
	-$(HALMOS) --contract HalmosPolicy --solver bitwuzla-abs --match-test '^check_(mintFee|redeemFee|rebaseStepBelow)'
	-$(HALMOS) --contract HalmosFwht --solver bitwuzla-abs --function check_
	-$(HALMOS) --contract HalmosToken --solver cvc5-int --function check_ --solver-timeout-assertion 3m

coverage:
	forge coverage --ir-minimum --report summary --no-match-coverage "^(test|script|lib)/" \
	  --no-match-test "test_record_worstCaseGasFitsHookBudget|test_entropy_gas"

sim:
	python3 sim/simulate.py

preflight-sepolia: _need-sepolia-rpc _need-deployer
	forge script script/DeployBaseMainnet.s.sol --rpc-url $(BASE_SEPOLIA_RPC_URL) --sender $(DEPLOYER)

deploy-base-sepolia: _need-sepolia-rpc _need-deployer _need-etherscan
	@test "$$(cast chain-id --rpc-url $(BASE_SEPOLIA_RPC_URL))" = "84532" || (echo "RPC is not Base Sepolia"; exit 1)
	forge script script/DeployBaseMainnet.s.sol --rpc-url $(BASE_SEPOLIA_RPC_URL) $(SIGNER) --sender $(DEPLOYER) \
	  --broadcast --slow --verify --etherscan-api-key $(ETHERSCAN_API_KEY)
	$(MAKE) post-deploy-check-sepolia

post-deploy-check-sepolia: _need-sepolia-rpc
	forge script script/PostDeployCheck.s.sol --rpc-url $(BASE_SEPOLIA_RPC_URL)

fork-test: _need-rpc
	forge test --match-contract BaseMainnetForkTest -vv

preflight: _need-rpc _need-deployer
	forge script script/DeployBaseMainnet.s.sol --rpc-url $(BASE_RPC_URL) --sender $(DEPLOYER)

deploy-base-mainnet: _need-rpc _need-deployer _need-etherscan
	@echo "Chain: $$(cast chain-id --rpc-url $(BASE_RPC_URL))  Deployer: $(DEPLOYER)  Signer: $(SIGNER)"
	@test "$$(cast chain-id --rpc-url $(BASE_RPC_URL))" = "8453" || (echo "RPC is not Base mainnet"; exit 1)
	@read -p "Broadcast the Spectrum deployment to Base MAINNET? Type 'deploy' to continue: " ans; \
	  [ "$$ans" = "deploy" ] || (echo "aborted"; exit 1)
	forge script script/DeployBaseMainnet.s.sol --rpc-url $(BASE_RPC_URL) $(SIGNER) --sender $(DEPLOYER) \
	  --broadcast --slow --verify --etherscan-api-key $(ETHERSCAN_API_KEY)
	$(MAKE) post-deploy-check

post-deploy-check: _need-rpc
	forge script script/PostDeployCheck.s.sol --rpc-url $(BASE_RPC_URL)

verify-base-mainnet: _need-etherscan
	script/verify.sh $(CHAIN_ID) etherscan

verify-blockscout:
	script/verify.sh $(CHAIN_ID) blockscout

clean-local:
	rm -f deployments/31337*.json && rm -rf broadcast/*/31337

_need-rpc:
	@test -n "$(BASE_RPC_URL)" || (echo "set BASE_RPC_URL (Base mainnet RPC)"; exit 1)

_need-sepolia-rpc:
	@test -n "$(BASE_SEPOLIA_RPC_URL)" || (echo "set BASE_SEPOLIA_RPC_URL (Base Sepolia RPC)"; exit 1)

_need-deployer:
	@test -n "$(DEPLOYER)" || (echo "set DEPLOYER (address of your Ledger/keystore account)"; exit 1)

_need-etherscan:
	@test -n "$(ETHERSCAN_API_KEY)" || (echo "set ETHERSCAN_API_KEY (Etherscan API V2 key)"; exit 1)
