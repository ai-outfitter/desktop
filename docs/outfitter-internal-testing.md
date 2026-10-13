# Internal Outfitter desktop testing

This build uses the workstation's unreleased `feat/cli-device-inference` code,
with local compatibility fixes for the desktop's separate state directory.
The local snapshot differs from the latest CLI PR #438, which has additional
concurrent credential persistence fixes. Validate the exact published CLI revision
before shipping this integration. No package release is required for internal testing.

Build and launch one internal app instance:

```sh
scripts/run-outfitter-app.sh
```

The bundle identifier is `com.ai-outfitter.desktop.internal`. Runtime state,
credentials and favorites live under `.local/outfitter-home/` and are ignored by
Git. The usual global Outfitter installation is unaffected. The launch script
also accepts an absolute `OUTFITTER_DESKTOP_CLI` path and an
`OUTFITTER_DESKTOP_AGENT` slug to use an existing CLI installation.

For this test, a separate workstation backend and database run on
`127.0.0.1:4481` in `webapp.worktrees/feat/desktop-device-test`. Its existing Spark
provider settings stay on the workstation. Forward it from the Mac:

```sh
ssh -N -L 127.0.0.1:4481:127.0.0.1:4481 ncrmro-workstation
```

This backend has separate local email/password accounts. In desktop Settings →
Models, choose **Sign in with Outfitter**, use the automatically provisioned local test account (both login fields are
pre-filled), then approve the displayed device request. The CLI stores the
device session and discovers `GLM-5.3-Flash-EXL3`. Start a new chat to test Spark.
Sending before connection retains the message and opens the connection screen.
Login resumes that message in its original project when a model is available.

The workstation implementation remains in progress; the desktop uses a local
snapshot. The server is loopback-only and accessible on the Mac through SSH.
This validates the unreleased device flow with real Spark, using a separate
local identity database. Production browser identity/deployment remains separate.

Verified during setup: actual CLI device issuance/approval/token exchange,
model discovery, Spark completion through Pi RPC, and a native conversation
model producing a response and returning to idle. User browser interaction and
visual UI inspection still need manual verification.

## Deployed model-routing preview

The shared device/model routing is deployed at
https://feat-device-model-routing.ai-outfitter.dev (webapp PR #322).
The current internal app uses `http://localhost:4482`, forwarded over SSH to a
workstation loopback API relay for that preview. Browser approval redirects to
the preview; API calls remain on the configured localhost origin. Preview access
credentials stay on the workstation. Relaunch this target with:

```sh
OUTFITTER_DESKTOP_ORIGIN=http://localhost:4482 scripts/run-outfitter-app.sh
```

Verified live: the actual CLI browser-login flow through the relay, model
discovery, Flash streaming/tool calls, Sol and Luna streaming/tool calls,
refresh rotation and revocation. The deployed preview already has working
platform provider configuration. Flash resolves to `GLM-5.3-Flash-EXL3`.

After successful sign-in, idle chat processes restart to adopt the newly approved
credentials while retaining the conversation and draft. Running, loading and
queued conversations are preserved. The native live regression starts a real Pi
process before credential installation and verifies the same conversation sends
through the deployed provider afterward.

The catalog exposes canonical `gpt-6-sol`, `gpt-6-luna`, `gpt-6-astra` and
`GLM-5.3-Flash-EXL3`; short aliases remain accepted by the server for older clients.
Live native tests confirmed Flash, Sol and Luna model selection and completed
responses. These tests are opt-in and require a disposable approved device session;
the default focused suite skips them rather than using the user's credentials.

Before a distributable release, merge/deploy WebApp #322, reconcile CLI #438
with the isolated-home fix, repeat acceptance on that exact CLI revision, and
replace the source-checkout runner/preview relay with the released CLI and deployed
service origin. WebApp's localhost test-account provisioning is separate work.
