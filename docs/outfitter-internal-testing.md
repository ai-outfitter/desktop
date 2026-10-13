# Outfitter desktop runtime

PiNative uses an installed `@ai-outfitter/outfitter` CLI. It does not import a
neighboring source checkout or require a development command wrapper.

Install the release into an application-owned prefix:

```sh
npm install -g --prefix .local/cli @ai-outfitter/outfitter
scripts/run-outfitter-app.sh
```

The launcher prefers `.local/cli/bin/outfitter`, then an installed `outfitter` on
PATH. `OUTFITTER_DESKTOP_CLI` can select another absolute installed executable;
`OUTFITTER_DESKTOP_AGENT` selects the agent (default `desktop`).

`scripts/configure-outfitter-state.mjs` creates the initial desktop agent and
opt-in inference settings. Settings, credentials, sessions, and favorites stay
under `.local/outfitter-home/`, which Git ignores. PiNative passes that location
as `OUTFITTER_USER_HOME` to both login and RPC subprocesses. The CLI projects it
into Pi and uses it for durable refresh and logout, preserving the OS home.

New configuration uses `https://ai-outfitter.com`. Existing configuration retains
its origin. Set `OUTFITTER_DESKTOP_ORIGIN` when launching to deliberately change
an existing desktop origin (including an HTTPS preview or loopback test service).
Credentials remain bound to their original origin; sign in again after changing it.

Choose **Sign in with Outfitter** under Settings → Models and approve the device
in your browser. Sending before connection retains the message and opens Models
settings. Once the catalog includes a preferred model, sign-in submits the message
once. Idle conversations restart after approval while preserving drafts; busy
conversations continue. Catalog discovery shows canonical `gpt-6-*` IDs and
`GLM-5.3-Flash-EXL3`, without duplicate aliases.

## Live acceptance

The optional native tests use a separately approved, disposable device session
and a temporary application home. `OUTFITTER_LIVE_CLI` selects the installed package
under test; it defaults to `.local/cli/bin/outfitter`. Each test is bounded by the
unit runner's 30-second case and 60-second suite limits. Without the explicit live
enablement marker and disposable credential fixture, live tests skip.

Internal preview acceptance uses a loopback SSH relay on port 4482; preview
Access credentials remain on the workstation. This is a server transport for
internal testing, independent of the installed CLI. Public-service configuration
uses its HTTPS origin directly.
