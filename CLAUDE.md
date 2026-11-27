# Instructions for Claude

- Read `NOTES.md` first (history, checklist, open risks) and keep it updated with dated entries.
- This repo depends on `swa-azure-lab` (same VM, `LAB_DIR`): it sources that lab's `config.env` for names.
- The user is new to development: explain plainly, one copy-paste command per block, say where to run it (the VM).
- The user runs interactive logins themselves (`az login --use-device-code`).
- Never commit `config.env`, `state/`, or any token / JWT.
- After changing scripts: `bash -n` every changed `.sh`, then commit and push to `main`.
