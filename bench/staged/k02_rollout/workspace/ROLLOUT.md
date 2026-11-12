# Rollout: request timeouts in milliseconds

In every `[http]` section of `services/*/app.ini`, replace the setting `timeout` with
`request_timeout_ms`, in milliseconds: `30s` is 30000, `1.5s` is 1500, `500ms` is 500, `2m` is
120000, and a bare number is seconds. `timeout` in any other section (`[db]`, `[cache]`,
`[smtp]`) is a different setting: leave it. Leave every other setting as it is.

`python3 rollout.py check` checks the services against the config loader each one runs.
