#!/bin/sh
# Run with public Cloud Run/Firebase configuration; no AI provider key is bundled.
# Usage: scripts/run.sh [flutter run args...]
# Override the local file with AFTER_HUE_CONFIG=/path/to/config.json.
set -eu
cd "$(dirname "$0")/.."
config_path="${AFTER_HUE_CONFIG:-config/development.local.json}"
if [ ! -f "$config_path" ]; then
  echo "Missing $config_path. Follow the cloud configuration steps in README.md." >&2
  exit 1
fi
filtered_path=$(mktemp)
trap 'rm -f "$filtered_path"' EXIT HUP INT TERM
python3 - "$config_path" "$filtered_path" <<'PYTHON'
import json, sys
with open(sys.argv[1]) as f:
    supplied = json.load(f)
fields = ('AFTER_HUE_AI_URL', 'FIREBASE_WEB_API_KEY', 'FIREBASE_PROJECT_ID')
if any(not supplied.get(field) for field in fields):
    raise SystemExit('The three cloud client settings are required. See README.md.')
data = {field: supplied[field] for field in fields}
if 'AFTER_HUE_DEMO_TOOLS' in supplied:
    data['AFTER_HUE_DEMO_TOOLS'] = supplied['AFTER_HUE_DEMO_TOOLS']
with open(sys.argv[2], 'w') as f:
    json.dump(data, f)
PYTHON
flutter run --dart-define-from-file="$filtered_path" "$@"
