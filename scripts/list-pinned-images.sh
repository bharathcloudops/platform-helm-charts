#!/usr/bin/env bash

#==============================================================================
# PINNED RUNTIME IMAGE LIST
#==============================================================================

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
values_file="$repository_root/charts/wordpress/values.yaml"

pinned_image() {
  awk -v block="$1" '
    $0 ~ "^" block ":" { in_block = 1; next }
    in_block && /^[a-z]/ { in_block = 0; in_image = 0 }
    in_block && /^  [a-zA-Z]/ { in_image = ($1 == "image:") }
    in_block && in_image && $1 == "repository:" { repository = $2 }
    in_block && in_image && $1 == "tag:" { tag = $2 }
    in_block && in_image && $1 == "digest:" { digest = $2 }
    END { printf "%s:%s@%s\n", repository, tag, digest }
  ' "$values_file"
}

printf 'nginx %s\n' "$(pinned_image nginx)"
printf 'redis %s\n' "$(pinned_image redis)"
printf 'mariadb %s\n' "$(pinned_image mariadb)"
printf 'restic %s\n' "$(pinned_image backup)"
