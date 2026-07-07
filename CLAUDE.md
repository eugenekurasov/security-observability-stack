# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Compliance-oriented, multi-tenant observability infrastructure for Kubernetes-based platforms in regulated sectors (finance, healthcare). The stack is designed to be deployable via Terraform + Helm with tenant isolation and audit-friendly defaults built in.

Components: `terraform/` (cloud infra, RBAC, IAM — planned), `helm/observability-stack` (OTel Collector deployment, implemented), `otel-components/k8sapilogreceiver` (custom OTel component, implemented).

## k8sapilogreceiver (Go module)

Located at `otel-components/k8sapilogreceiver`. This is the only implemented component so far.

**Module path:** `github.com/YOUR_GITHUB_HANDLE/security-observability-stack/otel-components/k8sapilogreceiver`

### Commands

```bash
cd otel-components/k8sapilogreceiver

# Build
go build ./...  # requires Go 1.26+

# Test
go test ./...

# Single test
go test -run TestFooBar ./...

# Lint (requires golangci-lint)
golangci-lint run ./...

# Tidy dependencies
go mod tidy
```

### OTel Collector Builder (OCB)

The receiver is intended to be compiled into a custom collector binary via OCB. The OCB manifest lives at `otel-components/builder-config.yaml`. It must pin OTel component versions to exactly those in `go.mod`:

- `go.opentelemetry.io/collector/component` v0.156.0
- `go.opentelemetry.io/collector/consumer` v0.156.0
- `go.opentelemetry.io/collector/pdata` v1.62.0
- `go.opentelemetry.io/collector/receiver` v0.156.0

Version mismatches between the OCB manifest and `go.mod` are the most common build failure when adding custom components.

### Architecture of k8sapilogreceiver

The receiver streams container logs via `client-go`'s `CoreV1().Pods(ns).GetLogs()` — the same API path as `kubectl logs -f` — instead of mounting the host filesystem. This is a deliberate security design choice, not a limitation.

Key design decisions:
- **No hostPath, no DaemonSet required**: deploys as a normal Deployment/StatefulSet
- **RBAC-scoped access**: only needs `pods` (get/list/watch) and `pods/log` (get) on target namespaces — see `deploy/rbac.yaml`
- **Multi-tenant isolation**: RBAC is managed by the Helm chart (`helm/observability-stack`), not by `deploy/rbac.yaml` — that file is a standalone reference only. The chart creates Role/RoleBinding per namespace in `namespace` mode.

**Pod lifecycle flow:** `runPodInformer` → per-namespace `SharedIndexInformer` on pods → `onPodAdded`/`onPodDeleted` → `streamContainerLogs` goroutine per container, tracked in `activeStreams` map with per-stream cancel functions.

**Reconnect logic** in `streamContainerLogs`: exponential backoff (config: `reconnect_backoff`), resets on successful connect. After first connect, sets `sinceSeconds=0` to avoid re-reading history on reconnect within the same process lifetime.

**Log emission**: each line → `plog.Logs` with resource attributes `k8s.namespace.name`, `k8s.pod.name`, `k8s.container.name`.

**Known gaps** (`receiver.go`):
- Out-of-cluster kubeconfig mode is not yet implemented (`buildRESTConfig`)
- The `workqueue` created in `runPodInformer` is unused (placeholder for future work item deduplication)

## Helm chart (`helm/observability-stack`)

### Deployment modes

`mode: cluster` — ClusterRole + ClusterRoleBinding, watches all namespaces, node metrics available. Requires cluster-admin to install.

`mode: namespace` — Role + RoleBinding per namespace, scoped to `namespaces:` list (defaults to release namespace). Tenant self-installable with only namespace-admin rights.

### Signal flags

Each of `signals.logs.enabled`, `signals.metrics.enabled`, `signals.traces.enabled` gates both the RBAC permissions and the OTel receiver/pipeline. Setting a signal to `false` removes its permissions from the generated Role/ClusterRole entirely.

### Key architectural details

- **OTel config** is built in `templates/_collector-config.tpl` as a named template, included into `templates/configmap.yaml` with `| indent 4`. Edit the named template when changing receiver/pipeline logic.
- **RBAC** in `templates/rbac.yaml`: cluster mode produces one ClusterRole + ClusterRoleBinding; namespace mode ranges over `$targetNs` and produces one Role + RoleBinding per namespace.
- **`$targetNs`** is computed as `default (list .Release.Namespace) .Values.namespaces` in both the RBAC and config templates (cluster mode overrides it to `[]` for "all namespaces").
- **Collector image** (`collector.image.repository`) must be a custom OCB-built binary with `k8sapilogreceiver` included. The upstream `otel/opentelemetry-collector-contrib` image lacks it and will fail to start.
- **Replicas > 1 is unsafe**: `activeStreams` tracking in `k8sapilogreceiver` is in-process only. HA requires distributed stream coordination (not yet implemented).
- **Config checksum annotation** on the Deployment pod template forces a rollout on any config change.

### Commands

```bash
# Lint / dry-run
helm lint helm/observability-stack
helm template my-release helm/observability-stack --set mode=namespace

# Install (namespace mode, tenant self-install)
helm install my-tenant-obs helm/observability-stack \
  --namespace payments \
  --set tenantId=payments

# Install (cluster mode, platform admin)
helm install platform-obs helm/observability-stack \
  --namespace observability \
  --set mode=cluster \
  --set signals.metrics.scrapeNodes=true

# Disable a signal type
helm upgrade my-tenant-obs helm/observability-stack --set signals.traces.enabled=false
```

## Design principles

1. **No node-level trust**: log collection via API server, not hostPath mounts
2. **Tenant isolation via RBAC boundaries**: namespace-scoped Role/RoleBinding per tenant, not shared cluster credentials
3. **Compliance mapping planned**: SOC 2 / HIPAA control-by-control mapping in `compliance-mapping.md` (not yet written)
4. **Reproducible builds**: OCB manifest + `go.mod` checked in together

## Known trade-offs vs hostPath-based collectors

| Concern | Impact |
|---|---|
| API server load | One persistent log stream per container — needs sharding at scale |
| Log rotation gaps | Gaps possible if disconnected longer than kubelet retains rotated logs |
| Multiline / structured parsing | Not implemented; emits one log record per line |
