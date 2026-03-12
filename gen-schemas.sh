#!/usr/bin/env bash
set -euo pipefail
# Usage: ./gen-schemas.sh apps/kgateway.yaml apps/cilium.yaml

SCHEMA_CMD="uv run --with pyyaml python3 /tmp/openapi2jsonschema.py"
curl -sfL https://raw.githubusercontent.com/yannh/kubeconform/master/scripts/openapi2jsonschema.py \
  -o /tmp/openapi2jsonschema.py

# Given a GitHub tree URL (https://github.com/owner/repo/tree/ref/path/to/dir),
# fetch all YAML files in that directory and output them as a single multidoc stream.
fetch_github_folder() {
  python3 - "$1" <<'PYEOF'
import json, urllib.request, sys
# ['https:', '', 'github.com', 'owner', 'repo', 'tree', 'ref', 'path', ...]
parts = sys.argv[1].split('/')
owner_repo = parts[3] + '/' + parts[4]
ref = parts[6]
path = '/'.join(parts[7:])
url = f'https://api.github.com/repos/{owner_repo}/contents/{path}?ref={ref}'
entries = json.load(urllib.request.urlopen(url))
for e in entries:
    if e['name'].endswith(('.yaml', '.yml')):
        body = urllib.request.urlopen(e['download_url']).read().decode()
        print('---')
        print(body)
PYEOF
}

COUNT=0
for app_file in "$@"; do
  VERSION="$(yq '.version' "$app_file")"
  APP_NAME="$(basename "$app_file" .yaml)"
  OUTPUT_DIR="schemas/${APP_NAME}/${VERSION#v}"
  mkdir -p "$OUTPUT_DIR"

  FILE_URLS="$(yq '.fileUrls[]' "$app_file")" || true
  GITHUB_FOLDERS="$(yq '.githubFolders[]' "$app_file")" || true
  CHART_URL="$(yq '.helm.chartUrl // ""' "$app_file")"
  TEMPLATE="$(yq '.helm.template // false' "$app_file")"
  VALUES="$(yq '.helm.requiredValues // ""' "$app_file")"

  cd "$OUTPUT_DIR"
  echo "\nProcessing $APP_NAME version $VERSION"

  for url in $FILE_URLS; do
    version_url="${url//\$\{VERSION\}/$VERSION}"
    echo "Fetching CRDs from $version_url"
    $SCHEMA_CMD "$version_url"
  done

  for folder_url in $GITHUB_FOLDERS; do
    folder_url="${folder_url//\$\{VERSION\}/$VERSION}"
    fetch_github_folder "$folder_url" | $SCHEMA_CMD /dev/stdin
  done

  if [ -n "$CHART_URL" ]; then
    if [ "$TEMPLATE" = "true" ]; then
      echo "$VALUES" | helm template "$APP_NAME" "$CHART_URL" --version "$VERSION" -f - \
        | $SCHEMA_CMD /dev/stdin
    else
      helm show crds "$CHART_URL" --version "$VERSION" \
        | $SCHEMA_CMD /dev/stdin
    fi
  fi

  cd ../../../
  GENERATED=$(find "$OUTPUT_DIR" -name '*.json' | wc -l)
  COUNT=$((COUNT + GENERATED))
done

echo "# schemas generated: $COUNT"
if [ "$COUNT" -eq 0 ]; then
  echo "ERROR: No schemas were generated"
  exit 1
fi