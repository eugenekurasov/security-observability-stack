# AGENT.md

Guidance for AI coding assistants working in this repository. This file
is intentionally short: it's a map to where information actually lives,
not a copy of it. If you're editing something covered below, read the
linked doc first — and if you update behavior it describes, update that
doc, not this one.

## Where things live

- **Project overview, quick start, design principles, roadmap**: [README.md](README.md)
- **Architecture** (signal pipeline, deployment modes, scope): [docs/architecture.md](docs/architecture.md)
- **Step-by-step install/verify walkthrough**: [docs/getting-started.md](docs/getting-started.md)
- **Build / test / lint commands** (receiver and Helm chart): [CONTRIBUTING.md](CONTRIBUTING.md)
- **k8spodlogreceiver**: architecture notes, full config reference, known limitations: [otel-components/k8spodlogreceiver/README.md](otel-components/k8spodlogreceiver/README.md)
- **OCB build manifest** (component/version pinning vs `go.mod`): [otel-components/builder-config.yaml](otel-components/builder-config.yaml)
- **Helm chart**: values and behavior are documented inline in [helm/observability-stack/values.yaml](helm/observability-stack/values.yaml) and the templates under `helm/observability-stack/templates/`
- **CI**: three required workflows in `.github/workflows/` (`ci.yml`, `integration.yml`, `lint.yml`) — each has comments explaining non-obvious choices (e.g. why there are no `paths:` filters, why the integration timeout is what it is)

## Code-level gotchas not documented elsewhere

These are implementation details for anyone editing the Go source
directly — not user-facing, so they don't belong in the READMEs above.

- **`receiver.go` idle-connection cleanup**: `Start` builds the clientset
  via `rest.HTTPClientFor` + `kubernetes.NewForConfigAndClient` instead of
  the simpler `kubernetes.NewForConfig`, so `Shutdown` can call
  `httpClient.CloseIdleConnections()`. Cancelling the informer/stream
  context only aborts in-flight requests — it doesn't close idle
  keep-alive connections already in the transport pool, which otherwise
  leak as goroutines (caught by `goleak` in tests). Preserve this pattern
  if you rewrite `Start`/`Shutdown`, and apply the same fix in any test
  that builds its own clientset against a real cluster.
