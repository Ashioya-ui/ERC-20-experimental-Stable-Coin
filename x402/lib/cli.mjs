// True when the module at `url` is the program node was started with. npm runs a package's bins
// through symlinks (node_modules/.bin, the global bin directory) and, on Windows, through .cmd shims;
// hosts such as Claude Desktop start the file by a path they build themselves, with mixed
// separators. node reports the main module's real path. So both sides are resolved to real,
// normalised paths before comparing, and on Windows, whose paths ignore case (a drive letter can
// arrive as c: or C:), the comparison ignores case too.

import { realpathSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const real = (p) => {
  for (const f of [realpathSync.native, realpathSync]) {
    try {
      return f(p);
    } catch {
      // try the next way, then fall back to the path as given
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
