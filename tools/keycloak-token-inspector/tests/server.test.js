const assert = require("node:assert/strict");
const test = require("node:test");

const { createServer } = require("../server");

function base64url(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function cookie(jar, name) {
  const match = jar.find((cookie) => cookie.startsWith(`${name}=`));
  assert.ok(match, `${name} cookie was not set`);
  return match.split(";")[0].split("=").slice(1).join("=");
}

test("login redirects to Keycloak with PKCE and stores the transaction", async () => {
  const server = createServer({
    publicUrl: "https://keycloak.example",
    clientId: "tenant-demo",
    redirectUri: "http://localhost:8000/callback",
    realm: "saas",
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;

  try {
    const response = await fetch(`${origin}/login`, { redirect: "manual" });
    assert.equal(response.status, 302);
    const location = new URL(response.headers.get("location"));
    assert.equal(location.origin, "https://keycloak.example");
    assert.equal(location.pathname, "/realms/saas/protocol/openid-connect/auth");
    assert.equal(location.searchParams.get("client_id"), "tenant-demo");
    assert.equal(location.searchParams.get("response_type"), "code");
    assert.equal(location.searchParams.get("scope"), "openid profile email");
    assert.equal(location.searchParams.get("redirect_uri"), "http://localhost:8000/callback");
    assert.equal(location.searchParams.get("code_challenge_method"), "S256");
    assert.ok(location.searchParams.get("code_challenge"));
    assert.ok(location.searchParams.get("state"));
    assert.ok(location.searchParams.get("nonce"));

    const jar = response.headers.getSetCookie();
    for (const name of ["oidc_state", "oidc_verifier", "oidc_nonce"]) {
      assert.ok(cookie(jar, name));
      assert.ok(jar.some((value) => value.includes("HttpOnly")));
      assert.ok(jar.some((value) => value.includes("SameSite=Lax")));
    }
  } finally {
    server.close();
  }
});

test("callback validates state and renders the ID token", async () => {
  const idToken = [
    base64url({ alg: "RS256" }),
    base64url({
      sub: "user-1",
      preferred_username: "alice",
      org_id: "tenant-1",
    }),
    "signature",
  ].join(".");
  let exchanged;
  const server = createServer({
    publicUrl: "https://keycloak.example",
    clientId: "tenant-demo",
    redirectUri: "http://localhost:8000/callback",
    realm: "saas",
    exchangeCode: async (request) => {
      exchanged = request;
      return { id_token: idToken };
    },
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;

  try {
    const login = await fetch(`${origin}/login`, { redirect: "manual" });
    const jar = login.headers.getSetCookie();
    const state = cookie(jar, "oidc_state");
    const verifier = cookie(jar, "oidc_verifier");
    const nonce = cookie(jar, "oidc_nonce");

    const rejected = await fetch(`${origin}/callback?code=wrong-state&state=no-match`, {
      headers: { cookie: jar.join("; ") },
    });
    assert.equal(rejected.status, 400);

    const callback = await fetch(`${origin}/callback?code=test-code&state=${state}`, {
      headers: { cookie: jar.join("; ") },
    });
    assert.equal(callback.status, 200);
    const body = await callback.text();
    assert.ok(body.includes("user-1"));
    assert.ok(body.includes("alice"));
    assert.ok(body.includes("tenant-1"));
    assert.ok(body.includes(idToken));
    assert.ok(body.includes("This app does not verify the token signature."));
    assert.ok(body.includes("Sign out"));

    const callbackJar = callback.headers.getSetCookie();
    assert.ok(callbackJar.some((value) => value.startsWith("oidc_id_token=")));

    assert.equal(exchanged.code, "test-code");
    assert.equal(exchanged.codeVerifier, verifier);
    assert.equal(exchanged.nonce, nonce);
    assert.equal(exchanged.redirectUri, "http://localhost:8000/callback");
  } finally {
    server.close();
  }
});

test("logout redirects to Keycloak and clears the local session", async () => {
  const idToken = [
    base64url({ alg: "RS256" }),
    base64url({ sub: "user-1" }),
    "signature",
  ].join(".");
  const server = createServer({
    publicUrl: "https://keycloak.example",
    clientId: "tenant-demo",
    redirectUri: "http://localhost:8000/callback",
    realm: "saas",
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;

  try {
    const response = await fetch(`${origin}/logout`, {
      headers: { cookie: `oidc_id_token=${idToken}` },
      redirect: "manual",
    });
    assert.equal(response.status, 302);
    const location = new URL(response.headers.get("location"));
    assert.equal(location.origin, "https://keycloak.example");
    assert.equal(location.pathname, "/realms/saas/protocol/openid-connect/logout");
    assert.equal(location.searchParams.get("id_token_hint"), idToken);
    assert.equal(location.searchParams.get("post_logout_redirect_uri"), "http://localhost:8000/");

    const cookies = response.headers.getSetCookie();
    for (const name of ["oidc_state", "oidc_verifier", "oidc_nonce", "oidc_id_token"]) {
      assert.ok(cookies.some((value) => value.startsWith(`${name}=;`)), `${name} cookie was not cleared`);
    }
  } finally {
    server.close();
  }
});
