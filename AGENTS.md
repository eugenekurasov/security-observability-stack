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

- **`receiver.go` idle-connection cleanup**: `Start` builds one shared
  `httpClient` via `rest.HTTPClientFor` and passes it to
  `kubernetes.NewForConfigAndClient` rather than using the simpler
  `NewForConfig` — so log streaming and the pod informers share one transport
  pool that `Shutdown` can drain in a single call. Cancelling the informer or
  stream context only aborts in-flight requests; it does not close idle
  keep-alive connections already in the transport pool, which otherwise leak
  as goroutines (caught by `goleak` in tests). Preserve this pattern if you
  rewrite `Start`/`Shutdown`, and apply the same fix in any test that builds
  its own client against a real cluster.

- **Pod discovery lives in `internal/poddiscovery`**, a client-go
  `SharedIndexInformer` per configured namespace. The package knows nothing
  about log streams: it reports pods through a `Handler` of three callbacks,
  and `receiver.go`'s `startPodDiscovery` is the only place the two meet.
  Three details there are deliberate and easy to undo by accident:
  - **The ListWatch is built from the typed clientset, not
    `cache.NewFilteredListWatchFromClient`.** The latter needs a `RESTClient`
    that `fake.NewSimpleClientset` does not provide, so discovery would stop
    being testable without a real API server; the typed client also hands
    handlers `*corev1.Pod` directly, with no unstructured decoding.
  - **`podListWatch` opts out of WatchList (streaming list) semantics**, which
    client-go's `WatchListClient` gate enables by default. On an API server
    without streaming-list support the reflector waits ~10s for a bookmark
    that never arrives before falling back to a plain List, and repeats that
    on every re-list — the fallback is not sticky. The receiver's stated
    compatibility promise is plain List/Watch (stable since k8s 1.0), so the
    opt-out keeps startup identical on every supported version. Revisit when
    the minimum supported version has streaming lists.
  - **Handler callbacks must stay idempotent.** `ensureStreams` and
    `markContainerStates` run from `OnAdd` *and* `OnUpdate`, and `OnUpdate`
    also fires for every cached pod on each resync (`pod_resync_period`) —
    that repetition is what restarts a stream which gave up after
    `ReconnectBackoff.MaxElapsedTime`. `Start` rejects a Handler with any
    callback unset rather than panicking on the first event.

  This replaced a copy of contrib's `k8sinventory/watch` Observer, which had
  no cache and, on a 410 Gone, resumed from a fresh resourceVersion without
  reconciling: a pod created during the gap never produced an Added event, so
  its log stream never started. The informer re-lists and diffs against its
  cache, so both creations and deletions missed during a gap surface —
  deletions as `DeletedFinalStateUnknown` tombstones, which the package's
  `podFrom` unwraps so `OnDelete` still receives the pod.
