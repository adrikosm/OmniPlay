#!/bin/zsh
# Point git at the versioned hooks so the public-repo guard runs on every commit of every checkout.
cd "$(dirname "$0")/.." && git config core.hooksPath Scripts/hooks && echo "hooks: core.hooksPath = Scripts/hooks"
