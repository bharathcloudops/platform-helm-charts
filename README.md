# BharathCoudOps Platform Helm Charts

Reusable Helm charts maintained by `bharathadigopula`. GitHub Actions validates this public repository on hosted runners; consuming repositories own production deployment through their approved workflows.

## Contents

| Path | Purpose |
|---|---|
| `charts/web-service` | Web application, optional PostgreSQL, explicit migration Job, ingress and network policies |
| `charts/wordpress` | Reusable WordPress, Nginx, Redis, MariaDB, backup, restore, and verification workloads |
| `scripts` | Versioned offline validation and checksum-pinned CI tooling |
| `.github` | Validation, ownership and dependency updates |
| `docs` | Architecture, release and operational boundaries |

## Validation

```sh
bash scripts/validate.sh
shellcheck scripts/*.sh
bash scripts/smoke-kind.sh
```

Helm 3.18.4 is the pinned CI version. Validation does not contact a cluster. Render tests are not a substitute for an isolated-cluster deployment test.

The optional smoke test requires Docker, Kind, kubectl, Helm and OpenSSL. It creates and deletes a disposable Kind cluster with an explicit dedicated kubeconfig, enforces restricted pod security, tests application and PostgreSQL health, runs a no-op migration container, and verifies PVC retention after uninstall. It does not test application-specific migrations or network-policy enforcement (Kind's default CNI does not enforce NetworkPolicy).

## Consumer Configuration

Consumers check out a released version at its exact commit and keep environment values in their own repository. Create the namespace and the referenced Secrets through the approved secret-delivery workflow before installing. Use a dedicated kubeconfig explicitly for every production operation.

The image digests below are placeholders, not runnable images:

```yaml
image: example.invalid/app@sha256:0000000000000000000000000000000000000000000000000000000000000000
runtimeSecret: app-runtime
registrySecret: app-registry
replicas: 0
port: 3100
readinessPath: /api/health/ready
database:
  enabled: true
  image: postgres@sha256:0000000000000000000000000000000000000000000000000000000000000000
  existingSecret: app-database
  name: app
  username: app
  storageClass: local-path
  storage: 8Gi
migration:
  enabled: false
  image: example.invalid/migrate@sha256:0000000000000000000000000000000000000000000000000000000000000000
ingress:
  enabled: false
  className: traefik
  hostname: app.example.invalid
```

Validate privately held values with `helm template example charts/web-service --namespace example --values /path/to/private-values.yaml`. Do not put credential values in Helm values, command-line `--set`, rendered manifests, GitHub artifacts or logs.

## Pinned Runtime Images

Images are pinned by tag and digest in `charts/wordpress/values.yaml` and refreshed whenever upstream publishes security fixes.

| Component | Image | Version |
|---|---|---|
| Nginx | `nginxinc/nginx-unprivileged` | `1.30.6-alpine-slim` |
| Redis | `redis` | `8.2.10-alpine` |
| MariaDB | `mariadb` | `12.3.3` |
| Backup and restore | `restic/restic` | `0.19.1` |

The WordPress application image, including WordPress core and PHP, is built and pinned by each site repository rather than by this chart.

## Core Upgrades And Cron

WordPress core lives on its own persistent volume, and the upstream image entrypoint copies core only when that volume is empty. The `prepare-wordpress-webroot` init container therefore compares the core version in the image with the version on the volume and, when they differ, copies the new core files over the volume without touching `wp-content` or `wp-config.php`. Image upgrades now update WordPress core on the next rollout, and the init container logs `wordpress_core=<image> previous=<installed>`.

The `wordpress-cron` Job uses the same private image as the deployment, so it carries the same `imagePullSecrets`. Without them the Job cannot pull the image, stays in `ImagePullBackOff`, and holds the `Forbid` concurrency slot.

## Values Reference

| Key | Default | Description |
|---|---|---|
| `image` | empty, required | Runtime image including sha256 digest |
| `replicas` | `0` | Explicitly enable after restore/migration verification; 0-10 |
| `port` | `3100` | Unprivileged application/service port |
| `runtimeSecret` | empty, required | Existing same-namespace Secret containing application environment |
| `registrySecret` | empty | Optional existing registry pull Secret |
| `runAsUser`, `runAsGroup` | `1001` | Non-root app and migration identity |
| `readinessPath` | `/api/health/ready` | Startup/readiness HTTP endpoint; liveness uses TCP |
| `resources.requests` | `100m`, `256Mi` | App CPU/memory requests |
| `resources.limits` | `1`, `1Gi` | App CPU/memory limits |
| `migration.enabled` | `false` | Create revision-named migration Job; pipeline waits explicitly |
| `migration.image` | empty | Required immutable image when enabled; image CMD runs migration |
| `migration.databaseUrlKey` | `DATABASE_URL` | Runtime Secret key injected as DATABASE_URL |
| `database.enabled` | `false` | Create private PostgreSQL StatefulSet and headless Service |
| `database.image` | empty | Required immutable PostgreSQL image when enabled |
| `database.existingSecret` | empty | Existing Secret containing POSTGRES_PASSWORD; do not override POSTGRES_DB/USER there |
| `database.storageClass`, `database.storage` | `local-path`, `8Gi` | Persistent claim class/capacity; local-path does not support resizing |
| `database.runAsUser`, `database.runAsGroup` | `70`, `70` | PostgreSQL Alpine identity; match the chosen image |
| `database.name`, `database.username` | `app`, `app` | Initial database and role; runtime DATABASE_URL must match |
| `database.resources.requests` | `100m`, `256Mi` | PostgreSQL CPU/memory requests |
| `database.resources.limits` | `1`, `512Mi` | PostgreSQL CPU/memory limits |
| `ingress.enabled` | `false` | Opt-in host routing |
| `ingress.className`, `ingress.hostname` | `traefik`, empty | Controller class and required hostname when enabled |
| `ingress.tlsSecret` | empty | Existing TLS Secret; otherwise secured edge termination required |
| `networkPolicy.enabled` | `true`, required | Cannot be disabled through values |
| `networkPolicy.ingressNamespace` | `kube-system` | Namespace of the allowed ingress controller |
| `networkPolicy.ingressPodLabels` | `app.kubernetes.io/name: traefik` | Allowed controller pod selector |
| `networkPolicy.publicEgressPorts` | `[443, 587]` | Public TCP destinations; excludes private, loopback and link-local ranges |

The database hostname is `<release>-postgres`. PVCs survive StatefulSet deletion, but deleting the namespace can delete data. Deployment uses Recreate for constrained single-node hosts, so upgrades may interrupt traffic. Migration pods request 100m/256Mi and are limited to 1 CPU/512Mi with a ten-minute deadline. Temporary pod storage is capped at 64Mi; PostgreSQL runtime socket storage is 16Mi. No automatic database major-version upgrade is provided.

## WordPress Configuration

Each WordPress project owns a non-secret profile and consumes this shared chart through the versioned lifecycle automation. Use one namespace and one release per site. The profile can set `wordpress.configuration`, `wordpress.php`, `nginx.clientMaxBodySize`, all four persistence sizes, storage class, backup tag, schedule, and retention independently.

Normal deployment uses `helm upgrade --install --atomic --wait`. It never deletes a namespace or PVC. WordPress PVCs carry `helm.sh/resource-policy: keep`, MariaDB claim retention is `Retain`, and the lifecycle changes bound PV reclaim policy to `Retain`. A storage class is immutable after claim creation, so changing it for an existing site is rejected. Size increases still depend on the selected storage class; K3s `local-path` normally does not resize existing claims.

| Site value | Default | Effect |
|---|---|---|
| `wordpress.persistence.storageClass` | cluster default | Storage class for webroot, uploads, and extensions |
| `wordpress.persistence.size` | `15Gi` | Upload media capacity |
| `wordpress.persistence.coreSize` | `5Gi` | WordPress core and generated application files |
| `wordpress.persistence.extensionsSize` | `5Gi` | Dashboard-managed themes and plugins |
| `mariadb.persistence.size` | `10Gi` | Database capacity |
| `wordpress.configuration.memoryLimit` | `256M` | Front-end WordPress memory limit |
| `wordpress.configuration.maxMemoryLimit` | `512M` | Administrative WordPress memory limit |
| `wordpress.configuration.autosaveInterval` | `120` | Autosave interval in seconds |
| `wordpress.configuration.postRevisions` | `10` | Revisions retained per post |
| `wordpress.configuration.emptyTrashDays` | `14` | Trash retention in days |
| `wordpress.php.*` | see `values.yaml` | Per-site PHP upload, execution, input, memory, and OPcache limits |
| `nginx.clientMaxBodySize` | `128m` | Per-site request body limit |
| `backup.tag` | `wordpress` | Site-specific Restic snapshot tag |
| `backup.schedule` | `17 2 * * *` | Encrypted off-host backup schedule |
| `backup.retention` | 7 daily, 4 weekly, 6 monthly | Restic retention policy |

The `verify-backup` lifecycle renders `backup-verify-job.yaml`, runs `restic check`, restores the selected site tag into temporary `emptyDir` storage, and requires the database dump, webroot, extensions, and uploads. It does not mount or alter live PVCs. A real restore validates the snapshot before scaling WordPress down, takes a fresh pre-restore backup, recreates only the selected database, restores all content, and verifies WordPress and the public URL afterward.

K3s local-path PVCs survive pod and service restarts but remain tied to the host disk. They do not protect against boot-volume or host loss; encrypted Restic backups in OCI Object Storage are the disaster-recovery control.

See [operations](docs/operations.md) and [security](SECURITY.md) before production use.