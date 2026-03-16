#!/usr/bin/env bash
set -euo pipefail
# Usage: ./gen-schemas.sh apps/kgateway.yaml apps/cilium.yaml
# Usage: ./gen-schemas.sh apps/*

export FILENAME_FORMAT="{fullgroup}_{kind}_{version}"
SCHEMA_CMD="uv run --with pyyaml python3 /tmp/openapi2jsonschema.py"
curl -sfL https://raw.githubusercontent.com/yannh/kubeconform/master/scripts/openapi2jsonschema.py \
  -o /tmp/openapi2jsonschema.py

# Given a GitHub tree URL (https://github.com/owner/repo/tree/ref/path/to/dir),
# fetch all YAML files in that directory and output them as a single multidoc stream.
fetch_github_folder() {
  python3 - "$1" <<'PYEOF'
import json, os, urllib.request, sys
# ['https:', '', 'github.com', 'owner', 'repo', 'tree', 'ref', 'path', ...]
parts = sys.argv[1].split('/')
owner_repo = parts[3] + '/' + parts[4]
ref = parts[6]
path = '/'.join(parts[7:])
url = f'https://api.github.com/repos/{owner_repo}/contents/{path}?ref={ref}'
token = os.environ.get('GITHUB_TOKEN', '')
headers = {'Authorization': f'token {token}'} if token else {}
req = urllib.request.Request(url, headers=headers)
entries = json.load(urllib.request.urlopen(req))
for e in entries:
    if e['name'].endswith(('.yaml', '.yml')):
        dl_req = urllib.request.Request(e['download_url'], headers=headers)
        body = urllib.request.urlopen(dl_req).read().decode()
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
  VALUES_SCHEMA_URL="$(yq '.helm.valuesSchemaUrl // ""' "$app_file")"

  rm -rf "$OUTPUT_DIR"/*
  cd "$OUTPUT_DIR"
  echo ""
  echo "Processing $APP_NAME version $VERSION"

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
    PULL_DIR="$(mktemp -d)"
    helm pull "$CHART_URL" --version "$VERSION" --untar -d "$PULL_DIR"
    CHART_DIR="$(ls -d "$PULL_DIR"/*/)"
    
    if [ -n "$VALUES_SCHEMA_URL" ]; then
      if [ -f "$CHART_DIR/values.schema.json" ]; then
        echo "Found values schema in $APP_NAME chart"
        cp "$CHART_DIR/values.schema.json" values.schema.json
      fi
    fi
    
    if [ "$TEMPLATE" = "true" ]; then
      echo "$VALUES" | helm template "$APP_NAME" "$CHART_DIR" -f - \
        | $SCHEMA_CMD /dev/stdin
    else
      helm show crds "$CHART_DIR" \
        | $SCHEMA_CMD /dev/stdin
    fi

    rm -rf "$PULL_DIR"
  fi
  
  if [ -n "$VALUES_SCHEMA_URL" ]; then
    url="${VALUES_SCHEMA_URL//\$\{VERSION\}/$VERSION}"
    curl -sfL "$url" -o values.schema.json
  fi

  # Metadata for Group: Kind mapping
  cd ../../../
  rm -f "$OUTPUT_DIR/_groups.txt"
  for schema in "$OUTPUT_DIR"/*.json; do
    fname="$(basename "$schema" .json)"
    GROUP=$(echo "$fname" | cut -d_ -f1)
    KIND_VERSION=$(echo "$fname" | cut -d_ -f2-)
    echo "$GROUP ${KIND_VERSION}.json" >> "$OUTPUT_DIR/_groups.txt"
    mv "$schema" "$OUTPUT_DIR/${KIND_VERSION}.json"
  done
  
  GENERATED=$(find "$OUTPUT_DIR" -name '*.json' | wc -l)
  if [ "$GENERATED" -eq 0 ]; then
    echo "ERROR: no schemas generated for $APP_NAME. To debug, run: ./gen-schemas.sh $app_file" >&2
    exit 1
  fi
  COUNT=$((COUNT + GENERATED))
done

echo "# schemas generated: $COUNT"