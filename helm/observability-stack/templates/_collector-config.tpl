{{/*
Builds one collector's YAML config for a single group.

Called with a dict:
  root    — the chart root context (.)
  values  — the group's effective values (global overlaid with group overrides)
  signals — the list of ownership signals this group owns (subset of
            logs, metrics, events, traces)

Receivers/pipelines render only for the signals this group owns, so each
group's pod runs a minimal config. selfMonitoring is not an ownership signal:
it is a per-pod concern (this collector exposing its own telemetry) and renders
for every group whose effective values enable it. Extensions render per pod from
the effective diagnostics block.

Consumed by configmap.yaml via:
  include "observability-stack.collectorConfig" (dict "root" $root "values" $v "signals" $g.signals)
*/}}
{{- define "observability-stack.collectorConfig" -}}
{{- $root := .root -}}
{{- $v := .values -}}
{{- $signals := .signals -}}
{{- $targetNs := default (list $root.Release.Namespace) $v.namespaces -}}
{{- if eq $v.mode "cluster" }}{{- $targetNs = list }}{{- end -}}
receivers:
{{- if has "logs" $signals }}
  k8s_podlog:
    namespaces: {{ $targetNs | toJson }}
    pod_label_selector: {{ $v.signals.logs.podLabelSelector | quote }}
    since_seconds: {{ $v.signals.logs.sinceSeconds }}
    api_config:
      auth_type: serviceAccount
    reconnect_backoff:
      initial_interval: {{ $v.signals.logs.reconnectBackoff.initialInterval }}
      max_interval: {{ $v.signals.logs.reconnectBackoff.maxInterval }}
      max_elapsed_time: {{ $v.signals.logs.reconnectBackoff.maxElapsedTime }}
    max_batch_size: {{ $v.signals.logs.maxBatchSize }}
    flush_interval: {{ $v.signals.logs.flushInterval }}
    max_log_size: {{ int64 $v.signals.logs.maxLogSize }}
    max_log_size_behavior: {{ $v.signals.logs.maxLogSizeBehavior | quote }}
{{- end }}
{{- if has "metrics" $signals }}
  prometheus:
    config:
      global:
        scrape_interval: {{ $v.signals.metrics.scrapeInterval }}
      scrape_configs:
        - job_name: k8s-pods
          kubernetes_sd_configs:
            - role: pod
              {{- if $targetNs }}
              namespaces:
                names: {{ $targetNs | toJson }}
              {{- end }}
          relabel_configs:
            {{- if $v.signals.metrics.scrapeAnnotated }}
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: "true"
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
              action: replace
              regex: "([^:]+)(?::\\d+)?;(\\d+)"
              replacement: "$1:$2"
              target_label: __address__
            {{- end }}
            - source_labels: [__meta_kubernetes_namespace]
              target_label: k8s_namespace
            - source_labels: [__meta_kubernetes_pod_name]
              target_label: k8s_pod
            - source_labels: [__meta_kubernetes_pod_container_name]
              target_label: k8s_container
{{- if and (eq $v.mode "cluster") $v.signals.metrics.scrapeNodes }}
        - job_name: k8s-nodes-kubelet
          kubernetes_sd_configs:
            - role: node
          scheme: https
          tls_config:
            ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          relabel_configs:
            - action: labelmap
              regex: __meta_kubernetes_node_label_(.+)
            - target_label: __address__
              replacement: kubernetes.default.svc:443
            - source_labels: [__meta_kubernetes_node_name]
              regex: (.+)
              target_label: __metrics_path__
              replacement: /api/v1/nodes/$1/proxy/metrics
        - job_name: k8s-nodes-cadvisor
          kubernetes_sd_configs:
            - role: node
          scheme: https
          tls_config:
            ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          relabel_configs:
            - action: labelmap
              regex: __meta_kubernetes_node_label_(.+)
            - target_label: __address__
              replacement: kubernetes.default.svc:443
            - source_labels: [__meta_kubernetes_node_name]
              regex: (.+)
              target_label: __metrics_path__
              replacement: /api/v1/nodes/$1/proxy/metrics/cadvisor
{{- end }}
{{- if $v.signals.metrics.cluster }}
  k8s_cluster:
    auth_type: serviceAccount
    collection_interval: 30s
    {{- if $targetNs }}
    namespaces: {{ $targetNs | toJson }}
    {{- end }}
    # node_conditions_to_report and allocatable_types_to_report are left
    # empty in namespace mode — those require cluster-scoped node access.
    {{- if eq $v.mode "cluster" }}
    node_conditions_to_report: [Ready, MemoryPressure, DiskPressure]
    allocatable_types_to_report: [cpu, memory, storage]
    {{- end }}
{{- end }}
{{- end }}
{{- if has "events" $signals }}
  k8s_events:
    auth_type: serviceAccount
    {{- if $targetNs }}
    namespaces: {{ $targetNs | toJson }}
    {{- end }}
{{- end }}
{{- if has "traces" $signals }}
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:{{ $v.signals.traces.grpcPort }}"
      http:
        endpoint: "0.0.0.0:{{ $v.signals.traces.httpPort }}"
{{- end }}


processors:
  memory_limiter:
    check_interval: {{ $v.collector.processors.memoryLimiter.checkInterval }}
    limit_percentage: {{ $v.collector.processors.memoryLimiter.limitPercentage }}
    spike_limit_percentage: {{ $v.collector.processors.memoryLimiter.spikeLimitPercentage }}
  batch:
    timeout: {{ $v.collector.processors.batch.timeout }}
    send_batch_size: {{ $v.collector.processors.batch.sendBatchSize }}
    send_batch_max_size: {{ $v.collector.processors.batch.sendBatchMaxSize }}

{{/* One OTLP exporter for every pipeline. Printing records for inspection is
     deliberately not a chart feature: a debug exporter here would write to the
     same stdout the k8s_podlog receiver tails, so every record would be read
     back in and printed again. The examples run a separate gateway pod that
     does the printing instead — see the otel-gateway manifest in each
     directory under examples/. */}}
exporters:
  otlp:
    endpoint: {{ $v.collector.export.endpoint | quote }}
    tls:
      insecure: {{ $v.collector.export.tls.insecure }}

{{/* Collect enabled diagnostics extensions so both the extensions block and
     the service.extensions list below stay in sync from one source. */}}
{{- $extensions := list -}}
{{- if $v.healthCheck.enabled }}{{- $extensions = append $extensions "health_check" }}{{- end -}}
{{- if $v.diagnostics.pprof.enabled }}{{- $extensions = append $extensions "pprof" }}{{- end -}}
{{- if $v.diagnostics.zpages.enabled }}{{- $extensions = append $extensions "zpages" }}{{- end -}}
{{- if $extensions }}
extensions:
{{- if $v.healthCheck.enabled }}
  health_check:
    endpoint: "0.0.0.0:{{ $v.healthCheck.port }}"
{{- end }}
{{- if $v.diagnostics.pprof.enabled }}
  pprof:
    endpoint: {{ $v.diagnostics.pprof.endpoint | quote }}
{{- end }}
{{- if $v.diagnostics.zpages.enabled }}
  zpages:
    endpoint: {{ $v.diagnostics.zpages.endpoint | quote }}
{{- end }}
{{- end }}

service:
  {{- if $extensions }}
  extensions: [{{ join ", " $extensions }}]
  {{- end }}
  {{- if $v.signals.selfMonitoring.enabled }}
  telemetry:
    metrics:
      # `address` was removed in collector v0.156 in favour of the OpenTelemetry
      # SDK config schema; a pull reader with a Prometheus exporter is the
      # equivalent of the old host:port form.
      readers:
        - pull:
            exporter:
              prometheus:
                host: "0.0.0.0"
                port: {{ $v.signals.selfMonitoring.metricsPort }}
    resource:
      k8s.pod.name: "${env:K8S_POD_NAME}"
      k8s.namespace.name: "${env:K8S_NAMESPACE}"
      k8s.node.name: "${env:K8S_NODE_NAME}"
  {{- end }}
  pipelines:
{{- if has "logs" $signals }}
    logs:
      receivers: [k8s_podlog]
      processors: [memory_limiter, batch]
      exporters: [otlp]
{{- end }}
{{- if has "metrics" $signals }}
    metrics:
      receivers: [prometheus]
      processors: [memory_limiter, batch]
      exporters: [otlp]
{{- if $v.signals.metrics.cluster }}
    metrics/k8s:
      receivers: [k8s_cluster]
      processors: [memory_limiter, batch]
      exporters: [otlp]
{{- end }}
{{- end }}
{{- if has "events" $signals }}
    logs/events:
      receivers: [k8s_events]
      processors: [memory_limiter, batch]
      exporters: [otlp]
{{- end }}
{{- if has "traces" $signals }}
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp]
{{- end }}
{{- end -}}
