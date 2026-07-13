# Contributing

Contributions can target either the `k8spodlogreceiver` OTel component or
the `observability-stack` Helm chart.

## k8spodlogreceiver

### Build

```bash
cd otel-components/k8spodlogreceiver
go build ./...
```

### Unit tests

```bash
cd otel-components/k8spodlogreceiver
go test -v ./...
```

### Integration tests (kind cluster)

Requires Docker running and [`kind`](https://kind.sigs.k8s.io/):

```bash
brew install kind
kind create cluster --name k8spodlog-test --image kindest/node:v1.34.8
cd otel-components/k8spodlogreceiver
go test -v -tags integration -timeout 120s ./...
kind delete cluster --name k8spodlog-test
```

See [`otel-components/k8spodlogreceiver/README.md`](otel-components/k8spodlogreceiver/README.md#running-tests-locally)
for details (macOS `DOCKER_HOST` note, vendoring, cleanup gotchas).

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
[`otel-components/builder-config.yaml`](otel-components/builder-config.yaml).
`examples/cluster-mode` and `examples/namespace-mode` have sample
`values.yaml` overrides for each deployment mode.
