# Service policy

- **Memory.** A replica may use at most the plan's limit. Over it, lower the memory to the
  limit. A service of kind `api` scales out instead of up: it keeps its total memory, so its
  replicas grow by the same factor, rounded up.
- **Credentials.** No password or token in `env`. Put the variable's name in the service's
  `secrets` list and set its value in `env` to `secret:NAME`.
- **Ports.** Ports below 1024 belong to the router. A `web` service listens on 8080. When a
  port is taken on the cluster, use the next port above it.
- **Health.** Every service but a database has a `health` check: `{"path": "/healthz"}` for
  `web` and `api`, `{"command": "worker --ping"}` for a `worker`.
- **Dependencies.** A service may depend only on services in services/. If it depends on one
  that is not there, drop it when the service lists it under `optional`; otherwise leave it and
  report it.
