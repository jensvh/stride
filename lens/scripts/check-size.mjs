// The glasses want the first load under 300 KB. Counts what the app itself
// loads: not the probe page and not the demo chunk.
import { readdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const dist = join(dirname(fileURLToPath(import.meta.url)), '..', 'dist');
const LIMIT = 300_000;
let total = 0;
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name !== 'probe') walk(path);
    } else if (!name.startsWith('demo-')) {
      total += statSync(path).size;
    }
  }
};
walk(dist);
console.log(`lens first load: ${total} bytes (limit ${LIMIT})`);
process.exit(total < LIMIT ? 0 : 1);
