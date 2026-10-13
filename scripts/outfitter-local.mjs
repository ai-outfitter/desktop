#!/usr/bin/env node
// Internal desktop runner: use the real Outfitter command objects with a
// separate state directory, without changing the user's global CLI/config.
import { mkdirSync, existsSync, writeFileSync, readFileSync, renameSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = process.env.OUTFITTER_SOURCE_ROOT || resolve(desktop, '../outfitter');
const state = process.env.OUTFITTER_DESKTOP_STATE_DIRECTORY || join(desktop, '.local/outfitter-home');
const load = (path) => import(pathToFileURL(join(source, 'code/cli/dist', path)).href);
const { createOutfitterProgram } = await load('cli/OutfitterCli.js');
const { createRunAgentCommand } = await load('cli/commands/RunAgentCommand.js');
const { createHostedCommand } = await load('cli/commands/HostedCommand.js');
const { createHostedSession } = await load('hosted/HostedSession.js');
const { hostedOrigin } = await load('hosted/HostedClient.js');
const origin = hostedOrigin(process.env.OUTFITTER_DESKTOP_ORIGIN || 'http://localhost:4481');
mkdirSync(join(state, '.agents/agents/desktop'), { recursive: true, mode: 0o700 });
mkdirSync(join(state, '.pi/agent'), { recursive: true, mode: 0o700 });
const settingsPath = join(state, '.agents/settings.yml');
const settings = `default_agent: desktop\ntelemetry:\n  enabled: false\nexperimental:\n  outfitter_provider: true\n  outfitter_origin: ${JSON.stringify(origin)}\n`;
if (!existsSync(settingsPath) || readFileSync(settingsPath, 'utf8') !== settings) {
  const temporary = `${settingsPath}.${process.pid}`;
  writeFileSync(temporary, settings, { mode: 0o600 });
  renameSync(temporary, settingsPath);
}
const agent = join(state, '.agents/agents/desktop/agent.md');
if (!existsSync(agent)) writeFileSync(agent, '---\nname: desktop\nlabel: Outfitter Desktop\n---\nYou are a helpful coding assistant.\n', { mode: 0o600 });
const program = createOutfitterProgram([
  createRunAgentCommand({ homeDirectory: state }),
  createHostedCommand({ enabled: () => true, session: () => createHostedSession(state) })
]);
try {
  await program.parseAsync(process.argv);
} catch (error) {
  console.error(error instanceof Error ? error.message : 'Outfitter failed.');
  process.exitCode = 1;
}
