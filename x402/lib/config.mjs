// Addresses and EIP-712 domains of the rail on one chain, read from files the forge scripts
// write and from the network's own config:
//   deployments/<chainId>.json               a Spectrum deployment (sUSD, stabilizer, ...), optional
//   deployments/<chainId>-router.json        the sUSD pay router, optional (needs the above)
//   deployments/<chainId>-vault-router.json  VaultPayRouter, optional
//   config/<chainId>.json                    the network: USDC and the vaults it trusts
//
// A chain with no Spectrum deployment is complete with USDC and VaultPayRouter alone: that is the
// Base mainnet rail, where agents pay from an Aave position they already hold and nothing is
// issued.

import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { lc, isAddress, networkOf } from './protocol.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const readIf = (path) => (existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : null);

export async function loadDeployment(chain) {
  const chainId = await chain.chainId();
  const dir = process.env.DEPLOYMENTS_DIR || resolve(ROOT, 'deployments');
  const main = readIf(process.env.DEPLOYMENT || resolve(dir, `${chainId}.json`));
  const net = readIf(process.env.NETWORK_CONFIG || resolve(ROOT, 'config', `${chainId}.json`));
  const sUSDRouter = main ? readIf(process.env.ROUTER_DEPLOYMENT || resolve(dir, `${chainId}-router.json`))?.router : null;
  const vaultRouter = readIf(process.env.VAULT_ROUTER_DEPLOYMENT || resolve(dir, `${chainId}-vault-router.json`))?.router;

  const usdc = main?.usdc ?? net?.external?.usdc;
  if (!isAddress(usdc)) {
    throw new Error(`nothing known about chain ${chainId}: no deployments/${chainId}.json and no config/${chainId}.json`);
  }
  // The vaults this side trusts with a payment. VAULTS overrides; otherwise the network's own
  // primary vault, the one the fork tests run against. A payer may name any vault on-chain, but a
  // facilitator pays gas for every attempt and an agent signs for every one, so neither takes a
  // vault it has not chosen.
  const vaults = (process.env.VAULTS ? process.env.VAULTS.split(',') : [net?.external?.vault])
    .map((v) => String(v ?? '').trim())
    .filter(isAddress)
    .map(lc);

  const a = {
    sUSD: main ? lc(main.sUSD) : null,
    usdc: lc(usdc),
    stabilizer: main ? lc(main.stabilizer) : null,
    treasury: main ? lc(main.treasury) : null,
    lens: main ? lc(main.lens) : null,
    router: sUSDRouter ? lc(sUSDRouter) : null,
    vaultRouter: isAddress(vaultRouter) ? lc(vaultRouter) : null,
    vaults: [...new Set(vaults)],
  };
  const strip = (s) => String(s).replace(/^"|"$/g, '');
  const usdcDomain = {
    name: strip(await chain.call(a.usdc, 'name()(string)')),
    version: strip(await chain.call(a.usdc, 'version()(string)')),
  };
  return {
    chainId,
    network: networkOf(chainId),
    addresses: a,
    domains: {
      sUSD: main ? { name: 'Spectrum Agentic USD', version: '1' } : null,
      usdc: usdcDomain,
    },
  };
}
