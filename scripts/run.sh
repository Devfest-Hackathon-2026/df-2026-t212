#!/bin/sh
# Run After Hue with the OpenAI key read from 1Password at build time.
# Usage: scripts/run.sh [flutter run args...]
# Model can be overridden: OPENAI_MODEL=... scripts/run.sh
set -e
cd "$(dirname "$0")/.."
exec op run --env-file .env.op -- sh -c 'flutter run --dart-define=OPENAI_API_KEY="$OPENAI_API_KEY" --dart-define=OPENAI_MODEL="${OPENAI_MODEL:-gpt-6.1-terra}" "$@"' sh "$@"
