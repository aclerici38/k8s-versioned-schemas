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

# Filter CRDs out of multidocs and save to metadata.name
filter_crds() {
  local dir="$1" filtered
  filtered="$(yq eval 'select(.kind == "CustomResourceDefinition")' -)"
  [ -z "$filtered" ] && return
  mkdir -p "$dir"
  echo "$filtered" | yq eval -s "\"${dir}/\" + .metadata.name + \".yaml\"" -
}

COUNT=0
for app_file in "$@"; do
  VERSION="$(yq '.version' "$app_file")"
  APP_NAME="$(basename "$app_file" .yaml)"
  SCHEMAS_DIR="schemas/${APP_NAME}/${VERSION#v}"
  CRDS_DIR="crds/${APP_NAME}/${VERSION#v}"
  mkdir -p "$SCHEMAS_DIR"

  FILE_URLS="$(yq '.fileUrls[]' "$app_file")" || true
  GITHUB_FOLDERS="$(yq '.githubFolders[]' "$app_file")" || true
  CHART_URL="$(yq '.helm.chartUrl // ""' "$app_file")"
  TEMPLATE="$(yq '.helm.template // false' "$app_file")"
  VALUES="$(yq '.helm.requiredValues // ""' "$app_file")"
  VALUES_SCHEMA_URL="$(yq '.helm.valuesSchemaUrl // ""' "$app_file")"

  rm -f "${CRDS_DIR:?}"/* 2>/dev/null || true
  rm -f "${SCHEMAS_DIR:?}"/*
  echo ""
  echo "Processing $APP_NAME version $VERSION"

  for url in $FILE_URLS; do
    version_url="${url//\$\{VERSION\}/$VERSION}"
    echo "Fetching CRDs from $version_url"
    curl -sfL "$version_url" | filter_crds "$CRDS_DIR"
  done

  for folder_url in $GITHUB_FOLDERS; do
    folder_url="${folder_url//\$\{VERSION\}/$VERSION}"
    fetch_github_folder "$folder_url" | filter_crds "$CRDS_DIR"
  done

  if [ -n "$CHART_URL" ]; then
    PULL_DIR="$(mktemp -d)"
    helm pull "$CHART_URL" --version "$VERSION" --untar -d "$PULL_DIR"
    CHART_DIR="$(ls -d "$PULL_DIR"/*/)"

    if [ -z "$VALUES_SCHEMA_URL" ] && [ -f "$CHART_DIR/values.schema.json" ]; then
      echo "Found values schema in $APP_NAME chart"
      cp "$CHART_DIR/values.schema.json" "$SCHEMAS_DIR/values.schema.json"
    fi

    if [ "$TEMPLATE" = "true" ]; then
      echo "$VALUES" | helm template "$APP_NAME" "$CHART_DIR" -f - |
        filter_crds "$CRDS_DIR"
    else
      helm show crds "$CHART_DIR" |
        filter_crds "$CRDS_DIR"
    fi

    rm -rf "$PULL_DIR"
  fi

  if [ -n "$VALUES_SCHEMA_URL" ]; then
    url="${VALUES_SCHEMA_URL//\$\{VERSION\}/$VERSION}"
    curl -sfL "$url" -o "$SCHEMAS_DIR/values.schema.json"
  fi

  cd "$SCHEMAS_DIR"
  for crd in "../../../$CRDS_DIR"/*.yaml; do
    [ -f "$crd" ] || continue
    $SCHEMA_CMD "$crd"
  done

  # Metadata for Group: Kind mapping
  for schema in *.json; do
    case "$schema" in
    values.schema.json) continue ;;
    esac
    fname="${schema%.json}"
    GROUP=$(echo "$fname" | cut -d_ -f1)
    KIND_VERSION=$(echo "$fname" | cut -d_ -f2-)
    echo "$GROUP ${KIND_VERSION}.json" >>_groups.txt
    mv "$schema" "${KIND_VERSION}.json"
  done

  GENERATED=$(find . -name '*.json' | wc -l)
  if [ "$GENERATED" -eq 0 ]; then
    echo "ERROR: no schemas generated for $APP_NAME. To debug, run: ./gen-schemas.sh $app_file" >&2
    exit 1
  fi
  COUNT=$((COUNT + GENERATED))
  cd -
done

echo "# schemas generated: $COUNT"
