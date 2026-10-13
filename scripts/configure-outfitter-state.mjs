#!/usr/bin/env node
// Bootstrap application-owned configuration for the installed Outfitter CLI.
import { mkdirSync, existsSync, writeFileSync, readFileSync, renameSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const state = process.env.OUTFITTER_DESKTOP_STATE_DIRECTORY || join(desktop, '.local/outfitter-home');
const origin = process.env.OUTFITTER_DESKTOP_ORIGIN || 'https://ai-outfitter.com';
mkdirSync(join(state, '.agents/agents/desktop'), { recursive: true, mode: 0o700 });
mkdirSync(join(state, '.pi/agent'), { recursive: true, mode: 0o700 });
const settingsPath = join(state, '.agents/settings.yml');
const settings = `default_agent: desktop\ntelemetry:\n  enabled: false\nexperimental:\n  outfitter_provider: true\n  outfitter_origin: ${JSON.stringify(origin)}\n`;
if (!existsSync(settingsPath)) {
  writeFileSync(settingsPath, settings, { mode: 0o600 });
} else if (process.env.OUTFITTER_DESKTOP_ORIGIN) {
  const current = readFileSync(settingsPath, 'utf8');
  if (!/^\s+outfitter_origin:/m.test(current)) throw new Error('Set experimental.outfitter_origin in the existing desktop settings before overriding its origin.');
  const updated = current.replace(/^(\s+outfitter_origin:).*$/m, (_match, key) => `${key} ${JSON.stringify(origin)}`);
  const temporary = `${settingsPath}.${process.pid}`;
  writeFileSync(temporary, updated, { mode: 0o600 });
  renameSync(temporary, settingsPath);
}
const agent = join(state, '.agents/agents/desktop/agent.md');
if (!existsSync(agent)) writeFileSync(agent, '---\nname: desktop\nlabel: Outfitter Desktop\n---\nYou are a helpful coding assistant.\n', { mode: 0o600 });
