# kargo-config

Kargo promotion pipeline configuration and deployment-state store for a Talos Kubernetes cluster.

This repository is intentionally separate from [`argo-config`](https://github.com/rhoades-brown/argo-config). Kargo commits chart versions, image tags, and git tags to **this** repo during promotions. ArgoCD watches this repo for version changes and `argo-config` for application configuration. The split prevents a promotion from triggering an ArgoCD refresh that would re-trigger Kargo, breaking the feedback loop.

---

## How it works

```
Container registry / Helm repo / git tag
              │
              ▼
        Kargo Warehouse          watches for new versions
              │
              ▼
         Kargo Stage             auto-promotes to prod
              │  writes
        ┌─────┴──────────────────────────────────┐
        │                                         │
kargo-config/configs/{name}.yaml        argo-config/valuesfiles/{name}.yaml
  chart.version  ◄── updated                image.tag  ◄── updated (if image promotion)
  targetRevision ◄── updated (git tag)
        │
        ▼
 ArgoCD managed-apps ApplicationSet
 re-reads configs/{name}.yaml, syncs
 the updated chart version to the cluster
```

### Promotion steps (per app, defined in `kargo-loader/templates/kargo-stage.yaml`)

1. **Clone `kargo-config`** — checks out `main` into `./kargo`
2. **Clone `argo-config`** *(image promotions only)* — checks out `main` into `./argo`
3. **Update image tags** *(if configured)* — writes new image tag(s) to `argo-config/valuesfiles/{name}.yaml`, commits and pushes to `argo-config`
4. **Update chart version** *(if configured)* — writes new chart version to `kargo-config/configs/{name}.yaml`
5. **Update `targetRevision`** — writes the promotion tag name (`{project}-{promotion-id}`) to `kargo-config/configs/{name}.yaml`
6. **Commit and push to `kargo-config`**
7. **Create a git tag** on `kargo-config` via the GitHub API — the tag matches the `targetRevision` written in step 5, providing a stable, immutable ArgoCD source revision

ArgoCD then detects the new `targetRevision` in `configs/{name}.yaml`, diffs the cluster against the new chart version, and syncs.

---

## Directory structure

```
kargo-config/
├── configs/                     One YAML file per managed application
│   ├── cert-manager.yaml        Defines chart version, targetRevision, and Kargo pipeline config
│   ├── immich.yaml
│   ├── kargo.yaml               Kargo manages itself (self-upgrade)
│   ├── penpot.yaml
│   └── ...
│
├── apps/                        Helm chart – bootstrap for Kargo CRD ApplicationSet
│   └── templates/
│       └── applicationset.yaml  Generates {name}-kargo Applications from configs/*.yaml
│                                using kargo-loader as the Helm chart source
│
├── kargo-loader/                Helm chart – renders Kargo CRDs for one application
│   └── templates/
│       ├── kargo-project.yaml       Kargo Project (sync-wave 0 — creates the namespace)
│       ├── kargo-projectconfig.yaml Kargo ProjectConfig (sync-wave 1)
│       ├── kargo-warehouse.yaml     Kargo Warehouse — subscribes to images/charts/git (sync-wave 1)
│       └── kargo-stage.yaml         Kargo Stage — defines the promotion steps (sync-wave 2)
│
├── manifests/                   Raw Kubernetes manifests for Kargo itself
│   └── kargo/                   e.g. SharedSecret for GitHub API token
│
└── valuesfiles/                 Helm values for self-managed apps (e.g. Kargo)
    └── kargo.yaml
```

---

## configs/{name}.yaml schema

Each file drives both the ArgoCD Application (via `argo-config/apps/applicationset.yaml`) and the Kargo pipeline (via `kargo-config/apps/applicationset.yaml` → `kargo-loader`).

```yaml
name: myapp                          # App name; used as ArgoCD Application name
namespace: myapp                     # Target Kubernetes namespace

gitRepo: https://github.com/rhoades-brown/argo-config.git
targetRevision: kargo-myapp-prod.… # Git tag written by Kargo; ArgoCD uses this as source revision

chart:
  repoURL: https://charts.example.com
  name: myapp
  version: 1.2.3                    # Updated by Kargo on each chart promotion

valuesFile: valuesfiles/myapp.yaml  # Path in argo-config; read alongside the chart
manifestsPath: manifests/myapp      # Optional: raw manifests directory in argo-config

kargo:
  enabled: true
  project: kargo-myapp              # Kargo project name (also the CRD namespace)
  autoPromotionEnabled: true

  warehouse:
    interval: 10m0s
    images:
      - repoURL: ghcr.io/example/myapp
        tagSelectionStrategy: SemVer
        allowTags: "^v[0-9]+\\.[0-9]+\\.[0-9]+$"
    chart:
      repoURL: https://charts.example.com
      name: myapp
      semverConstraint: ">=1.0.0"   # Kargo will only promote versions matching this

  stage:
    imageUpdates:                   # Written to argo-config/valuesfiles/{name}.yaml
      - key: image.tag
        image: ghcr.io/example/myapp
        file: valuesfiles/myapp.yaml
```

### Warehouse subscription types

| Field | What Kargo watches |
|-------|--------------------|
| `warehouse.images[]` | Container image tags in a registry |
| `warehouse.chart` | Helm chart versions in a Helm/OCI repo |
| `warehouse.gitSource` | SemVer git tags on a third-party repo |

The Warehouse also subscribes to `argo-config` git for any paths listed under `valuesFile` / `manifestsPath`, so a manual config change in `argo-config` itself can also trigger a promotion.

---

## Sync waves

Kargo CRDs are applied by ArgoCD in order using `argocd.argoproj.io/sync-wave`:

| Wave | Resource | Reason |
|------|----------|--------|
| `0` | `Project` | Creates the Kargo namespace; must exist before anything else |
| `1` | `Warehouse`, `ProjectConfig` | Depend on the namespace |
| `2` | `Stage` | References the Warehouse by name |

---

## Secrets

The promotion stage authenticates to the GitHub API using a `SharedSecret` named `kargo-github-api-token` (stored in the `kargo` namespace). This is provisioned via External Secrets Operator from Pulumi ESC.

No secrets are stored in this repository.
