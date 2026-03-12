#!/usr/bin/env bash
set -euo pipefail
# Usage: ./gen-schemas.sh apps/kgateway.yaml apps/cilium.yaml

SCHEMA_CMD="uv run --with pyyaml python3 /tmp/openapi2jsonschema.py"
curl -sfL https://raw.githubusercontent.com/yannh/kubeconform/master/scripts/openapi2jsonschema.py \
  -o /tmp/openapi2jsonschema.py
  
COUNT=0
for app_file in "$@"; do
  VERSION="$(yq '.version' "$app_file")"
  APP_NAME="$(basename "$app_file" .yaml)"
  OUTPUT_DIR="schemas/${APP_NAME}/${VERSION#v}"
  mkdir -p "$OUTPUT_DIR"

  FILE_URLS="$(yq '.fileUrls[]' "$app_file")" || true
  CHART_URL="$(yq '.helm.chartUrl // ""' "$app_file")"
  TEMPLATE="$(yq '.helm.template // false' "$app_file")"
  VALUES="$(yq '.helm.requiredValues // ""' "$app_file")"

  cd "$OUTPUT_DIR"

  for url in $FILE_URLS; do
    version_url="${url//\$\{version\}/$VERSION}"
    $SCHEMA_CMD "$version_url"
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