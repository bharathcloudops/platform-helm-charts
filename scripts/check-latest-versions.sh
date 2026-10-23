#!/usr/bin/env bash

#==============================================================================
# PINNED RUNTIME IMAGE DRIFT CHECK
#==============================================================================

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
values_file="$repository_root/charts/wordpress/values.yaml"
drift=0

#==============================================================================
# REGISTRY LOOKUPS
#==============================================================================

registry_token() {
  curl --fail --silent --show-error \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$1:pull" | jq -r '.token'
}

latest_tag() {
  local repository="$1"
  local pattern="$2"
  local token

  token=$(registry_token "$repository")
  curl --fail --silent --show-error --header "Authorization: Bearer $token" \
    "https://registry-1.docker.io/v2/$repository/tags/list?n=10000" |
    jq -r '.tags[]' | grep -E "$pattern" | sort -V | tail -n 1
}

tag_digest() {
  local repository="$1"
  local tag="$2"
  local token

  token=$(registry_token "$repository")
  curl --silent --head --header "Authorization: Bearer $token" \
    --header 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
    "https://registry-1.docker.io/v2/$repository/manifests/$tag" |
    tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}'
}

pinned_value() {
  awk -v block="$1" -v key="$2" '
    $0 ~ "^" block ":" { in_block = 1; next }
    in_block && /^[a-z]/ { in_block = 0; in_image = 0 }
    in_block && /^  [a-zA-Z]/ { in_image = ($1 == "image:") }
    in_block && in_image && $1 == key ":" { print $2; exit }
  ' "$values_file"
}

#==============================================================================
# COMPONENT COMPARISON
#==============================================================================

check_component() {
  local label="$1"
  local block="$2"
  local repository="$3"
  local pattern="$4"
  local pinned_tag
  local pinned_digest
  local latest
  local current_digest

  pinned_tag=$(pinned_value "$block" tag)
  pinned_digest=$(pinned_value "$block" digest)
  latest=$(latest_tag "$repository" "$pattern")
  current_digest=$(tag_digest "$repository" "$pinned_tag")

  if [[ -z "$latest" || -z "$pinned_tag" ]]; then
    printf '%s: could not determine pinned or latest tag.\n' "$label" >&2
    drift=1
    return
  fi
  if [[ "$pinned_tag" != "$latest" ]]; then
    printf '%s: pinned %s but %s is available.\n' "$label" "$pinned_tag" "$latest" >&2
    drift=1
  elif [[ -n "$current_digest" && "$pinned_digest" != "$current_digest" ]]; then
    printf '%s: tag %s was rebuilt upstream; pinned digest %s but current %s.\n' "$label" "$pinned_tag" "$pinned_digest" "$current_digest" >&2
    drift=1
  else
    printf '%s=current (%s)\n' "$label" "$pinned_tag"
  fi
}

nginx_minor=$(pinned_value nginx tag | sed -E 's/^([0-9]+\.[0-9]+)\..*/\1/')
redis_minor=$(pinned_value redis tag | sed -E 's/^([0-9]+\.[0-9]+)\..*/\1/')
mariadb_minor=$(pinned_value mariadb tag | sed -E 's/^([0-9]+\.[0-9]+)\..*/\1/')

check_component nginx nginx nginxinc/nginx-unprivileged "^${nginx_minor//./\\.}\\.[0-9]+-alpine-slim$"
check_component redis redis library/redis "^${redis_minor//./\\.}\\.[0-9]+-alpine$"
check_component mariadb mariadb library/mariadb "^${mariadb_minor//./\\.}\\.[0-9]+$"
check_component restic backup restic/restic '^[0-9]+\.[0-9]+\.[0-9]+$'

if (( drift != 0 )); then
  printf 'Pinned runtime images are behind upstream; update charts/wordpress/values.yaml.\n' >&2
  exit 1
fi
printf 'image_drift=none\n'
