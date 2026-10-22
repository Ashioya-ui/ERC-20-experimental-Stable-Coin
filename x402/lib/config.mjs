// Addresses and EIP-712 domains of a Spectrum deployment, read from the deployment JSON files
// the forge scripts write (deployments/<chainId>.json and deployments/<chainId>-router.json).

import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { lc, networkOf } from './protocol.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

export async function loadDeployment(chain) {
  const chainId = await chain.chainId();
  const dir = process.env.DEPLOYMENTS_DIR || resolve(ROOT, 'deployments');
  const main = JSON.parse(readFileSync(process.env.DEPLOYMENT || resolve(dir, `${chainId}.json`), 'utf8'));
  const routerPath = process.env.ROUTER_DEPLOYMENT || resolve(dir, `${chainId}-router.json`);
  const router = existsSync(routerPath) ? JSON.parse(readFileSync(routerPath, 'utf8')).router : null;
  const a = {
    sUSD: lc(main.sUSD),
    usdc: lc(main.usdc),
    stabilizer: lc(main.stabilizer),
    treasury: lc(main.treasury),
    lens: lc(main.lens),
    router: router ? lc(router) : null,
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
      sUSD: { name: 'Spectrum Agentic USD', version: '1' },
      usdc: usdcDomain,
    },
  };
}
