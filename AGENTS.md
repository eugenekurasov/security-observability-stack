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
  `httpClient` via `rest.HTTPClientFor`, then passes it to both
  `kubernetes.NewForConfigAndClient` (typed clientset, for log streaming)
  and `dynamic.NewForConfigAndClient` (dynamic client, for the pod-discovery
  `watch.Observer`) instead of the simpler `NewForConfig` — so both clients
  share one transport pool and `Shutdown` can drain it with a single
  `httpClient.CloseIdleConnections()`. Cancelling the observer/stream
  context only aborts in-flight requests — it doesn't close idle
  keep-alive connections already in the transport pool, which otherwise
  leak as goroutines (caught by `goleak` in tests). Preserve this pattern
  if you rewrite `Start`/`Shutdown`, and apply the same fix in any test
  that builds its own client against a real cluster.

- **Pod discovery uses `internal/watch` (Observer), not a client-go
  informer**: `startPodObserver` runs a copied-from-contrib List+Watch loop
  (`internal/watch`, a faithful copy of `k8sinventory/watch`) rather than a
  `SharedInformerFactory`. It has no local cache and no periodic resync: it
  emits the initial pod list once (`IncludeInitialState`), then streams
  Added/Modified/Deleted. On a 410 Gone it resumes from a fresh
  resourceVersion **without** re-listing (same as contrib's
  `k8sobjectsreceiver`, which is built on this same Observer), so a pod
  created during a 410 gap is not re-emitted as Added. This matters more here
  than in k8sobjectsreceiver: there a missed Added is one lost record, but
  here it would mean a pod's log stream never starts (unbounded loss). It is
  mitigated in `handlePodEvent`: Modified events also call `ensureStreams`
  (idempotent), so a pod created during the gap is picked up on its next
  update rather than only on process restart. `ensureStreams` deliberately
  does NOT bump the `added` discovery counter so per-Modified calls don't
  inflate it. `handlePodEvent` converts the Observer's
  `*unstructured.Unstructured` back to a typed `*corev1.Pod`. The gap-free
  alternative is k8sinventory's PullMode observer (periodic full re-List,
  which is its `DefaultMode`) — not used here to keep watch's instant
  reaction and low API load.

- **`internal/watch` dropped the upstream checkpointer**: contrib's
  `k8sinventory/watch` persists the watch resourceVersion to a storage
  extension so discovery resumes across restarts; that whole mechanism
  (`checkpointer.go`, the `storage.Client` arg to `watch.New`, the
  persisted-RV skip in `sendInitialState`, the checkpointer branch of
  `getResourceVersion`) was removed here. Reason: it only makes sense for a
  synchronous emitter like `k8sobjectsreceiver` (a committed RV means "every
  record up to here was delivered"). This receiver starts a long-lived log
  stream as a *side effect* of discovering a pod, so a committed discovery RV
  can advance past a pod whose stream isn't yet durable — and on restart
  `sendInitialState` would skip it (an at-most-once "lose a pod" hazard) with
  no benefit to log continuity. Real log-restart continuity would need
  per-container log-offset checkpointing (last delivered `SinceTime`), a
  separate mechanism. So `internal/watch` is intentionally NOT a byte-faithful
  copy of contrib's watch; the divergence is documented in the header of
  `observer.go`. When adopting contrib's package directly, its `watch.New`
  reintroduces the `storage.Client` arg — pass nil.
