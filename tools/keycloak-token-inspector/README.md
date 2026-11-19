# Keycloak token inspector

This tool runs on your computer. It starts a local OpenID Connect client and shows the ID token that Keycloak returns.

Use Node.js with built-in `fetch`, Bash, `base64`, and `kubectl`. Select the Kubernetes
context that contains Keycloak. Your account needs permission to read its Route
and client Secret and to forward a port to the Keycloak Service.

From the repository root, run:

```sh
tools/keycloak-token-inspector/run-local.sh
```

Open `http://localhost:8000`, then select `Sign in`. The script reads the Keycloak Route and client Secret from the current Kubernetes context. It also starts a temporary Kubernetes port-forward for the token exchange.

The script uses realm `saas` and client `tenant-demo`. Its environment overrides are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `KEYCLOAK_NAMESPACE` | `maas-db` | Namespace containing Keycloak and its Secret. |
| `PORT` | `8000` | Local browser port and callback port. |
| `FORWARD_PORT` | `18080` | Local port forwarded to the Keycloak Service. |

The default callback URL is `http://localhost:8000/callback`. The Keycloak
redirect-URI reconciler allows that URL. Changing `PORT` also changes the callback,
which requires separate redirect registration. The reconciler restores its own
redirect list every five minutes.

The page shows the decoded token claims and the raw ID token. It does not verify the token signature. Use it for manual testing only.

Select `Sign out` to end the Keycloak session and clear the local sign-in cookies.

Stop the script with `Ctrl+C` to stop the server and its temporary port-forward.

Two incognito windows in the same browser share one cookie jar. To compare two users at the same time, use two separate browser profiles or two different browsers.

Run the tests:

```sh
node --test tools/keycloak-token-inspector/tests/server.test.js
```
