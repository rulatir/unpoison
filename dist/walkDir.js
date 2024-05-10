// src/walkDir.ts
import fs from 'fs/promises';
import path from 'path';
export async function* walkDir(dir) {
    for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
        const res = path.resolve(dir, entry.name);
        if (entry.isDirectory())
            yield* walkDir(res);
        yield [res, entry];
    }
}
