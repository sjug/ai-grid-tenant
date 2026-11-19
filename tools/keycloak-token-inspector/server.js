"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const http = require("node:http");

function randomValue() {
  return crypto.randomBytes(32).toString("base64url");
}

function codeChallenge(verifier) {
  return crypto.createHash("sha256").update(verifier).digest("base64url");
}

function parseCookies(header) {
  if (!header) {
    return new Map();
  }
  return new Map(
    header.split(";").map((part) => {
      const separator = part.indexOf("=");
      return [part.slice(0, separator).trim(), part.slice(separator + 1)];
    }),
  );
}

function cookie(name, value) {
  return `${name}=${value}; Path=/; Max-Age=600; HttpOnly; SameSite=Lax`;
}

function clearCookie(name) {
  return `${name}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax`;
}

function decodeIdToken(idToken) {
  const parts = idToken.split(".");
  assert.equal(parts.length, 3, "the ID token must have three parts");
  return {
    header: JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8")),
    payload: JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")),
  };
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function page(title, body) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)}</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 2rem; }
    pre, textarea { width: 100%; box-sizing: border-box; overflow-wrap: anywhere; }
    textarea { height: 10rem; }
  </style>
</head>
<body>${body}</body>
</html>`;
}

async function exchangeCode({ code, codeVerifier, redirectUri }) {
  const tokenUrl = new URL(
    `/realms/${process.env.KEYCLOAK_REALM}/protocol/openid-connect/token`,
    process.env.KEYCLOAK_URL,
  );
  const response = await fetch(tokenUrl, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: process.env.KEYCLOAK_CLIENT_ID,
      client_secret: process.env.KEYCLOAK_CLIENT_SECRET,
      code,
      code_verifier: codeVerifier,
      redirect_uri: redirectUri,
    }),
  });
  if (!response.ok) {
    throw new Error(`token exchange failed: HTTP ${response.status}`);
  }
  return response.json();
}

function createServer(options = {}) {
  const publicUrl = options.publicUrl ?? process.env.KEYCLOAK_PUBLIC_URL;
  const clientId = options.clientId ?? process.env.KEYCLOAK_CLIENT_ID;
  const redirectUri = options.redirectUri ?? process.env.KEYCLOAK_REDIRECT_URI;
  const realm = options.realm ?? process.env.KEYCLOAK_REALM;
  const exchange = options.exchangeCode ?? exchangeCode;

  return http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, "http://localhost");
      if (request.method !== "GET" || url.pathname === "/") {
        if (request.method !== "GET") {
          response.writeHead(405).end();
          return;
        }
        const cookies = parseCookies(request.headers.cookie);
        const signedIn = Boolean(cookies.get("oidc_id_token"));
        response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        response.end(page("Keycloak token inspector", `
          <h1>Keycloak token inspector</h1>
          <p><a href="/login">Sign in</a></p>
          ${signedIn ? '<p><a href="/logout">Sign out</a></p>' : ""}
        `));
        return;
      }

      if (url.pathname === "/login") {
        const state = randomValue();
        const verifier = randomValue();
        const nonce = randomValue();
        const authorizationUrl = new URL(
          `/realms/${realm}/protocol/openid-connect/auth`,
          publicUrl,
        );
        authorizationUrl.search = new URLSearchParams({
          client_id: clientId,
          response_type: "code",
          scope: "openid profile email",
          redirect_uri: redirectUri,
          state,
          nonce,
          code_challenge: codeChallenge(verifier),
          code_challenge_method: "S256",
        });
        response.writeHead(302, {
          location: authorizationUrl,
          "set-cookie": [
            cookie("oidc_state", state),
            cookie("oidc_verifier", verifier),
            cookie("oidc_nonce", nonce),
          ],
        });
        response.end();
        return;
      }

      if (url.pathname === "/callback") {
        const cookies = parseCookies(request.headers.cookie);
        const state = url.searchParams.get("state");
        const code = url.searchParams.get("code");
        if (!state || !code || state !== cookies.get("oidc_state")) {
          response.writeHead(400, { "content-type": "text/html; charset=utf-8" });
          response.end(page("Invalid sign-in", "<h1>Invalid sign-in state</h1>"));
          return;
        }
        const codeVerifier = cookies.get("oidc_verifier");
        const nonce = cookies.get("oidc_nonce");
        const tokens = await exchange({
          code,
          codeVerifier,
          nonce,
          redirectUri,
        });
        const decoded = decodeIdToken(tokens.id_token);
        response.writeHead(200, {
          "content-type": "text/html; charset=utf-8",
          "set-cookie": [
            clearCookie("oidc_state"),
            clearCookie("oidc_verifier"),
            clearCookie("oidc_nonce"),
            cookie("oidc_id_token", tokens.id_token),
          ],
        });
        response.end(page("ID token", `
          <h1>ID token</h1>
          <p>This app does not verify the token signature. It only decodes and displays the token.</p>
          <h2>Claims</h2>
          <pre>${escapeHtml(JSON.stringify(decoded.payload, null, 2))}</pre>
          <h2>Raw token</h2>
          <textarea readonly>${escapeHtml(tokens.id_token)}</textarea>
          <p><a href="/login">Sign in again</a></p>
          <p><a href="/logout">Sign out</a></p>
        `));
        return;
      }

      if (url.pathname === "/logout") {
        const cookies = parseCookies(request.headers.cookie);
        const idToken = cookies.get("oidc_id_token");
        const endSessionUrl = new URL(
          `/realms/${realm}/protocol/openid-connect/logout`,
          publicUrl,
        );
        endSessionUrl.search = new URLSearchParams({
          id_token_hint: idToken ?? "",
          post_logout_redirect_uri: `${new URL(redirectUri).origin}/`,
        });
        response.writeHead(302, {
          location: endSessionUrl,
          "set-cookie": [
            clearCookie("oidc_state"),
            clearCookie("oidc_verifier"),
            clearCookie("oidc_nonce"),
            clearCookie("oidc_id_token"),
          ],
        });
        response.end();
        return;
      }

      response.writeHead(404, { "content-type": "text/html; charset=utf-8" });
      response.end(page("Not found", "<h1>Not found</h1>"));
    } catch (error) {
      response.writeHead(500, { "content-type": "text/html; charset=utf-8" });
      response.end(page("Sign-in failed", `<h1>Sign-in failed</h1><pre>${escapeHtml(error.message)}</pre>`));
    }
  });
}

module.exports = { createServer, decodeIdToken };

if (require.main === module) {
  createServer().listen(Number(process.env.PORT ?? 8080), "0.0.0.0");
}
