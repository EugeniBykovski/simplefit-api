import Config

# Force HTTPS in production and send HSTS. TLS is expected to terminate at
# a load balancer / reverse proxy that sets `x-forwarded-proto`; the app
# trusts that header, so it must only be reachable through such a proxy.
# The health endpoint is excluded so plain-HTTP health checks from the load
# balancer are not redirected. `:force_ssl` must be set at compile time.
config :simple_fit, SimpleFitWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    hsts: true,
    exclude: [
      paths: ["/api/health"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Structured JSON logs in production, one object per line, carrying the
# request id. Log aggregation (CloudWatch, Datadog, Loki, ...) can index the
# fields without regex parsing.
# One JSON object per line. Metadata is an allow-list; credentials that
# slip into metadata are redacted by key as defence in depth.
config :logger, :default_handler,
  formatter:
    {LoggerJSON.Formatters.Basic,
     metadata: [
       :service,
       :environment,
       :release,
       :request_id,
       :otel_trace_id,
       :otel_span_id,
       :method,
       :route,
       :status,
       :duration_ms,
       :provider,
       :reason,
       :missing,
       :worker,
       :queue,
       :job_id,
       :attempt,
       :max_attempts,
       :state,
       :error_kind,
       :error_type
     ],
     redactors: [
       {LoggerJSON.Redactors.RedactKeys,
        ["password", "secret", "token", "authorization", "api_key", "cookie"]}
     ]}

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
