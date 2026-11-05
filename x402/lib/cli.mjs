// isMain: true when the module is the program node started.
import { realpathSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const real = (p) => {
  for (const f of [realpathSync.native, realpathSync]) {
    try {
      return f(p);
    } catch {
    }
  }
  return resolve(p);
};
const same = (a, b) => (process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b);

export function isMain(url) {
  try {
    const started = process.argv[1];
    if (!started) return false;
    const self = fileURLToPath(url);
    return same(resolve(real(started)), resolve(real(self))) || same(resolve(started), resolve(self));
  } catch {
    return false;
  }
}
