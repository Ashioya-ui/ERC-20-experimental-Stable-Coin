// True when the module at `url` is the program node was started with. npm runs a package's bins
// through symlinks (node_modules/.bin, the global bin directory), and node reports the main
// module's real path, so the symlink in argv[1] is resolved before comparing.

import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function isMain(url) {
  try {
    return url === pathToFileURL(realpathSync(process.argv[1])).href;
  } catch {
    return false;
  }
}
