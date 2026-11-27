# Instructions for Claude

- Read `NOTES.md` first (history, checklist, open risks) and keep it updated with dated entries.
- `swa-lab/` is the SWA lab (Azure-adapted test-swa-docker); root scripts source `swa-lab/config.env` via `LAB_DIR`.
- Never commit `swa-lab/release/`, `swa-lab/.token`, `swa-lab/conjur` or the SWA bundle.
- The user is new to development: explain plainly, one copy-paste command per block, say where to run it (the VM).
- The user runs interactive logins themselves (`az login --use-device-code`).
- Never commit `config.env`, `state/`, or any token / JWT.
- After changing scripts: `bash -n` every changed `.sh`, then commit and push to `main`.
