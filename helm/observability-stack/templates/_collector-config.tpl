{{/*
Builds the OTel Collector YAML config.

Receivers, processors, pipelines, and (in cluster mode) scrape jobs are all
gated on the corresponding signals.* flag so the config is minimal by default
and RBAC stays tight — only permissions actually needed are granted.

Consumed by configmap.yaml via:  {{ include "observability-stack.collectorConfig" . | indent 4 }}
*/}}
{{- define "observability-stack.collectorConfig" -}}
{{- $targetNs := default (list .Release.Namespace) .Values.namespaces -}}
{{- if eq .Values.mode "cluster" }}{{- $targetNs = list }}{{- end -}}
receivers:
{{- if .Values.signals.logs.enabled }}
  k8s_podlog:
    namespaces: {{ $targetNs | toJson }}
    pod_label_selector: {{ .Values.signals.logs.podLabelSelector | quote }}
    since_seconds: {{ .Values.signals.logs.sinceSeconds }}
    api_config:
      auth_type: serviceAccount
    reconnect_backoff:
      initial_interval: {{ .Values.signals.logs.reconnectBackoff.initialInterval }}
      max_interval: {{ .Values.signals.logs.reconnectBackoff.maxInterval }}
      max_elapsed_time: {{ .Values.signals.logs.reconnectBackoff.maxElapsedTime }}
    max_batch_size: {{ .Values.signals.logs.maxBatchSize }}
    flush_interval: {{ .Values.signals.logs.flushInterval }}
    max_log_size: {{ int64 .Values.signals.logs.maxLogSize }}
    max_log_size_behavior: {{ .Values.signals.logs.maxLogSizeBehavior | quote }}
{{- end }}
{{- if .Values.signals.metrics.enabled }}
  prometheus:
    config:
      global:
        scrape_interval: {{ .Values.signals.metrics.scrapeInterval }}
      scrape_configs:
        - job_name: k8s-pods
          kubernetes_sd_configs:
            - role: pod
              {{- if $targetNs }}
              namespaces:
                names: {{ $targetNs | toJson }}
              {{- end }}
          relabel_configs:
            {{- if .Values.signals.metrics.scrapeAnnotated }}
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
{{- if and (eq .Values.mode "cluster") .Values.signals.metrics.scrapeNodes }}
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
{{- end }}
{{- if .Values.signals.events.enabled }}
  k8s_events:
    auth_type: serviceAccount
    {{- if $targetNs }}
    namespaces: {{ $targetNs | toJson }}
    {{- end }}
{{- end }}
{{- if .Values.signals.traces.enabled }}
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:{{ .Values.signals.traces.grpcPort }}"
      http:
        endpoint: "0.0.0.0:{{ .Values.signals.traces.httpPort }}"
{{- end }}
{{- if .Values.signals.selfMonitoring.enabled }}
  k8s_cluster:
    auth_type: serviceAccount
    collection_interval: 30s
    {{- if $targetNs }}
    namespaces: {{ $targetNs | toJson }}
    {{- end }}
    # node_conditions_to_report and allocatable_types_to_report are left
    # empty in namespace mode — those require cluster-scoped node access.
    {{- if eq .Values.mode "cluster" }}
    node_conditions_to_report: [Ready, MemoryPressure, DiskPressure]
    allocatable_types_to_report: [cpu, memory, storage]
    {{- end }}
{{- end }}


processors:
  memory_limiter:
    check_interval: {{ .Values.collector.processors.memoryLimiter.checkInterval }}
    limit_percentage: {{ .Values.collector.processors.memoryLimiter.limitPercentage }}
    spike_limit_percentage: {{ .Values.collector.processors.memoryLimiter.spikeLimitPercentage }}
  batch:
    timeout: {{ .Values.collector.processors.batch.timeout }}
    send_batch_size: {{ .Values.collector.processors.batch.sendBatchSize }}
    send_batch_max_size: {{ .Values.collector.processors.batch.sendBatchMaxSize }}
{{- if .Values.signals.selfMonitoring.enabled }}
  k8sattributes:
    auth_type: serviceAccount
    extract:
      metadata:
        - k8s.pod.name
        - k8s.pod.uid
        - k8s.deployment.name
        - k8s.namespace.name
        - k8s.node.name
      labels:
        - tag_name: app.kubernetes.io/name
          key: app.kubernetes.io/name
          from: pod
        - tag_name: app.kubernetes.io/version
          key: app.kubernetes.io/version
          from: pod
{{- end }}

exporters:
  otlp:
    endpoint: {{ .Values.collector.export.endpoint | quote }}
    tls:
      insecure: {{ .Values.collector.export.tls.insecure }}

service:
  {{- if .Values.signals.selfMonitoring.enabled }}
  telemetry:
    metrics:
      address: "0.0.0.0:{{ .Values.signals.selfMonitoring.metricsPort }}"
    resource:
      k8s.pod.name: "${env:K8S_POD_NAME}"
      k8s.namespace.name: "${env:K8S_NAMESPACE}"
      k8s.node.name: "${env:K8S_NODE_NAME}"
  {{- end }}
  pipelines:
{{- if .Values.signals.logs.enabled }}
    logs:
      receivers: [k8s_podlog]
      processors: [memory_limiter{{ if .Values.signals.selfMonitoring.enabled }}, k8sattributes{{ end }}, batch]
      exporters: [otlp]
{{- end }}
{{- if .Values.signals.metrics.enabled }}
    metrics:
      receivers: [prometheus]
      processors: [memory_limiter{{ if .Values.signals.selfMonitoring.enabled }}, k8sattributes{{ end }}, batch]
      exporters: [otlp]
{{- end }}
{{- if .Values.signals.events.enabled }}
    logs/events:
      receivers: [k8s_events]
      processors: [memory_limiter{{ if .Values.signals.selfMonitoring.enabled }}, k8sattributes{{ end }}, batch]
      exporters: [otlp]
{{- end }}
{{- if .Values.signals.traces.enabled }}
    traces:
      receivers: [otlp]
      processors: [memory_limiter{{ if .Values.signals.selfMonitoring.enabled }}, k8sattributes{{ end }}, batch]
      exporters: [otlp]
{{- end }}
{{- if .Values.signals.selfMonitoring.enabled }}
    metrics/k8s:
      receivers: [k8s_cluster]
      processors: [memory_limiter, k8sattributes, batch]
      exporters: [otlp]
{{- end }}
{{- end }}
