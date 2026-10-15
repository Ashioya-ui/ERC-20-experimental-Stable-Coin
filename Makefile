# Spectrum Protocol: build, test, rehearse and deploy.
#
# Mainnet sequence (see RUNBOOK_MAINNET.md):
#   make test rehearsal                  # everything local, no keys
#   make fork-test                       # same scenarios on a Base mainnet fork (BASE_RPC_URL)
#   make preflight                       # full deployment simulated against live Base state
#   make deploy-base-mainnet             # broadcast + verify (Ledger by default)
#   make post-deploy-check               # read-only checks against the live deployment
#   make verify-base-mainnet             # re-verify with explicit constructor args if needed
#
# Settings come from the environment or a .env file (see .env.example).

-include .env
export

SIGNER   ?= --ledger
CHAIN_ID ?= 8453

.PHONY: help build test test-ci rehearsal fork-test preflight deploy-base-mainnet \
        verify-base-mainnet verify-blockscout post-deploy-check sizes clean-local

help:
	@grep -E '^#' Makefile | sed 's/^# \{0,1\}//'

build:
	forge build --sizes

test:
	forge test

test-ci:
	FOUNDRY_PROFILE=ci forge test

sizes:
	forge build --sizes | grep -E "Spectral|Autonomous|Wrapped"

rehearsal:
	script/rehearsal/run.sh

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

_need-deployer:
	@test -n "$(DEPLOYER)" || (echo "set DEPLOYER (address of your Ledger/keystore account)"; exit 1)

_need-etherscan:
	@test -n "$(ETHERSCAN_API_KEY)" || (echo "set ETHERSCAN_API_KEY (Etherscan API V2 key)"; exit 1)
