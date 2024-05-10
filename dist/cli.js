#!/usr/bin/env node
// Import required modules
import { Command } from 'commander';
import { walkDir } from "./walkDir.js";
import path from "path";
import limax from "limax";
import fs from "fs/promises";
// Create a new command instance
const program = new Command();
program
    .version('0.0.1')
    .description('An example CLI program');
program
    .option('-n, --dry-run', 'Dry run', false)
    .action(async (options) => {
    for await (let [filepath, entry] of walkDir('.')) {
        const fname = path.basename(filepath);
        const renamed = `${path.dirname(filepath)}/${fname.split('.').map(chunk => limax(chunk.replace(/_/g, ' '), { maintainCase: true })).join('.')}`;
        if (renamed !== filepath) {
            if (options.dryRun) {
                console.log(`${filepath} -> ${renamed}`);
            }
            else {
                await fs.rename(filepath, renamed);
            }
        }
    }
});
async function main() {
    await program.parse(process.argv);
}
// Call the main function
// @ts-ignore
await main();
