# Contributing

This repository holds the `observability-stack` Helm chart and the OCB
manifest for the `secobs-collector` image.

The `k8spodlogreceiver` OTel component lives in its own repository —
[eugenekurasov/k8spodlogreceiver](https://github.com/eugenekurasov/k8spodlogreceiver).
Send changes to the receiver (code, tests, config reference) there; this
repo only consumes it as a pinned module in
[`builder-config.yaml`](builder-config.yaml).

## Collector image

### Build

```bash
docker build -t secobs-collector:0.1.0 .
```

The Dockerfile runs OCB against `builder-config.yaml` and
pulls every component — including `k8spodlogreceiver` — from the module
proxy. Nothing is built from local sources.

### Build without Docker

```bash
go install go.opentelemetry.io/collector/cmd/builder@v0.159.0
builder --config=builder-config.yaml
```

Keep the OCB version, `otelcol_version`, and every `gomod` line in the
manifest on the same collector release; mismatches are the most common
build failure.

## Helm chart

### Lint and render

```bash
helm lint helm/observability-stack
helm template my-obs helm/observability-stack --namespace payments
```

### Validate against a cluster

```bash
kind create cluster --name obs-stack-test
helm install my-obs helm/observability-stack \
  --namespace payments --create-namespace \
  --set tenantId=payments
kubectl -n payments get pods
helm uninstall my-obs -n payments
kind delete cluster --name obs-stack-test
```

The collector image referenced in `values.yaml` must include
`k8spodlogreceiver` (it's not in the upstream
`otel/opentelemetry-collector-contrib` image) — see
[`builder-config.yaml`](builder-config.yaml).
`examples/cluster-mode` and `examples/namespace-mode` have sample
`values.yaml` overrides for each deployment mode.
