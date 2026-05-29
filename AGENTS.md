# Agent Instructions

- After making repository changes, build and install the macOS app unless the user explicitly says not to install it.
- Use `scripts/build-app.sh release` to create the app bundle.
- Install the generated `.build/release/Droid Scout.app` bundle to `/Applications/Droid Scout.app`.
- If sandboxing blocks the build or install step, request escalation instead of skipping installation.
