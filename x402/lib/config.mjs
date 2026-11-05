// Addresses and EIP-712 domains for a chain, from deployments/ and config/.
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
  const sessionEscrow = readIf(process.env.SESSION_ESCROW_DEPLOYMENT || resolve(dir, `${chainId}-session-escrow.json`))?.escrow;
  const sessionPaths = readIf(process.env.SESSION_PATHS_DEPLOYMENT || resolve(dir, `${chainId}-session-paths.json`))?.paths;

  const usdc = main?.usdc ?? net?.external?.usdc;
  if (!isAddress(usdc)) {
    throw new Error(`nothing known about chain ${chainId}: no deployments/${chainId}.json and no config/${chainId}.json`);
  }
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
    sessionEscrow: isAddress(sessionEscrow) ? lc(sessionEscrow) : null,
    sessionPaths: isAddress(sessionPaths) && isAddress(sessionEscrow) ? lc(sessionPaths) : null,
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
