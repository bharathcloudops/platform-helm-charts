#!/usr/bin/env bash

#==============================================================================
# OFFLINE SHARED CHART VALIDATION - NEVER CONTACTS A CLUSTER
#==============================================================================

set -euo pipefail

#==============================================================================
# SYNTHETIC INPUTS AND STRICT CHART LINT
#==============================================================================
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
digest=$(printf '%064d' 0)
inputs=(--namespace example --set-string "image=example.invalid/app@sha256:$digest" --set-string runtimeSecret=example-runtime)
helm lint "$root/charts/web-service" --strict "${inputs[@]}"

#==============================================================================
# SAFE DEFAULTS: NO RUNNING APP, SECRET PAYLOADS OR OPTIONAL WORKLOADS
#==============================================================================
base=$(helm template example "$root/charts/web-service" "${inputs[@]}")
grep -Fq 'replicas: 0' <<< "$base"
if grep -Eq '^kind: (Secret|Ingress|Job|StatefulSet|ClusterRole|ClusterRoleBinding)$' <<< "$base"; then exit 1; fi

#==============================================================================
# OPTIONAL WORKLOAD RENDERING AND HARDENING CONTRACT
#==============================================================================
full=$(helm template example "$root/charts/web-service" "${inputs[@]}" --set database.enabled=true,migration.enabled=true,ingress.enabled=true,replicas=1 --set-string "database.image=postgres@sha256:$digest" --set-string database.existingSecret=example-database --set-string "migration.image=example.invalid/migrate@sha256:$digest" --set-string ingress.hostname=app.example.invalid)
for kind in Deployment StatefulSet Job Ingress NetworkPolicy; do grep -Fq "kind: $kind" <<< "$full"; done
grep -Fq 'automountServiceAccountToken: false' <<< "$full"
grep -Fq 'whenDeleted: Retain' <<< "$full"

#==============================================================================
# RESERVED NAMESPACES MUST FAIL CLOSED
#==============================================================================
for namespace in default kube-system kube-public kube-node-lease; do
  if helm template example "$root/charts/web-service" "${inputs[@]}" --namespace "$namespace" >/dev/null 2>&1; then exit 1; fi
done

#==============================================================================
# MUTABLE IMAGES, MISSING SECRETS AND UNSAFE VALUES MUST BE REJECTED
#==============================================================================
if helm template example "$root/charts/web-service" "${inputs[@]}" --set-string image=example.invalid/app:latest >/dev/null 2>&1; then exit 1; fi
if helm template example "$root/charts/web-service" "${inputs[@]}" --set-string runtimeSecret= >/dev/null 2>&1; then exit 1; fi
for invalid in runAsUser=0 database.runAsUser=0 networkPolicy.enabled=false port=80 replicas=-1; do
  if helm template example "$root/charts/web-service" "${inputs[@]}" --set "$invalid" >/dev/null 2>&1; then exit 1; fi
done
if helm template example "$root/charts/web-service" "${inputs[@]}" --set-string password=not-allowed >/dev/null 2>&1; then exit 1; fi

#==============================================================================
# SHARED WORDPRESS PLATFORM CONTRACT
#==============================================================================
wordpress=$(helm template wordpress "$root/charts/wordpress" --namespace ignitox \
  --set backup.enabled=true --set backup.restore.enabled=true \
  --set backup.restore.id=validation)
wordpress_custom=$(helm template wordpress "$root/charts/wordpress" --namespace custom-site \
  --set-string wordpress.php.memoryLimit=384M \
  --set-string wordpress.configuration.memoryLimit=192M \
  --set-string nginx.clientMaxBodySize=64m)
wordpress_verify=$(helm template wordpress "$root/charts/wordpress" --namespace ignitox \
  --set backup.enabled=true --set backup.verify.enabled=true \
  --set backup.verify.id=validation)
helm lint "$root/charts/wordpress" --strict --namespace ignitox
for resource in wordpress-core wordpress-extensions wordpress-uploads redis mariadb wordpress-backup; do
  grep -Fq "name: $resource" <<< "$wordpress"
done
grep -Fq 'restic backup --tag "wordpress" /backup/database.sql /webroot /extensions /uploads' <<< "$wordpress"
grep -Fq 'fastcgi_cache WORDPRESS;' <<< "$wordpress"
grep -Fq 'cp -R /usr/src/wordpress/wp-content/themes/. /extensions/themes/' <<< "$wordpress"
grep -Fq 'set -eu' <<< "$wordpress"
grep -Fq 'chown -R 0:0 /var/www/html /extensions /nginx-cache' <<< "$wordpress"
grep -Fq 'if [ ! -r /extensions/plugins/redis-cache/dependencies/predis/predis/autoload.php ]; then' <<< "$wordpress"
grep -Fq 'rm -rf /extensions/plugins/redis-cache' <<< "$wordpress"
grep -Fq 'cp -R /usr/src/wordpress/wp-content/plugins/redis-cache /extensions/plugins/redis-cache' <<< "$wordpress"
grep -Fq 'test -r /extensions/plugins/redis-cache/redis-cache.php' <<< "$wordpress"
grep -Fq 'test -r /extensions/plugins/redis-cache/dependencies/predis/predis/autoload.php' <<< "$wordpress"
grep -Fq 'cp /usr/src/wordpress/wp-content/plugins/redis-cache/includes/object-cache.php /extensions/object-cache.php' <<< "$wordpress"
[[ "$(grep -Fc 'subPath: object-cache.php' <<< "$wordpress")" == "2" ]]
grep -Fq "define('WP_REDIS_GRACEFUL', true);" <<< "$wordpress"
[[ "$(grep -Fc 'helm.sh/resource-policy: keep' <<< "$wordpress")" == "3" ]]
grep -Fq 'whenDeleted: Retain' <<< "$wordpress"
grep -Fq 'whenScaled: Retain' <<< "$wordpress"
grep -Fq 'restic check' <<< "$wordpress"
grep -Fq 'restic restore "latest" --tag "wordpress" --target /restore' <<< "$wordpress"
grep -Fq 'test -s /restore/backup/database.sql' <<< "$wordpress"
grep -Fq 'DROP DATABASE IF EXISTS' <<< "$wordpress"
grep -Fq 'memory_limit = 384M' <<< "$wordpress_custom"
grep -Fq "define('WP_MEMORY_LIMIT', '192M');" <<< "$wordpress_custom"
grep -Fq 'client_max_body_size 64m;' <<< "$wordpress_custom"
chmod_line=$(grep -nF 'chmod -R u+rwX /var/www/html' <<< "$wordpress" | cut -d: -f1)
chown_line=$(grep -nF 'chown -R 33:33 /var/www/html' <<< "$wordpress" | cut -d: -f1)
(( chmod_line < chown_line ))
grep -Fq 'name: wordpress-backup-verify-validation' <<< "$wordpress_verify"
grep -Fq 'name: XDG_CACHE_HOME' <<< "$wordpress_verify"
grep -Fq 'value: /tmp' <<< "$wordpress_verify"
grep -Fq 'restic restore "latest" --tag "wordpress" --target /verify' <<< "$wordpress_verify"
grep -Fq 'wordpress_backup_verification=ready' <<< "$wordpress_verify"
operations_policy=$(sed -n '/name: wordpress-operations/,/^---$/p' <<< "$wordpress_verify")
grep -Fq -- '- backup-verify' <<< "$operations_policy"
grep -Fq 'port: 443' <<< "$operations_policy"
if grep -Fq 'bharathcoudops' <<< "$wordpress"; then exit 1; fi
grep -Fq 'chmod u+rwX,g+rX,o+rX' <<< "$wordpress"
grep -Fq 'wordpress_core=' <<< "$wordpress"

#==============================================================================
# BOUNDED VALIDATION RESULT
#==============================================================================
printf 'shared_helm_validation=ready\n'