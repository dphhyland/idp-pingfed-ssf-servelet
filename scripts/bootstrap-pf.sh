#!/usr/bin/env bash
# One-time OAuth bootstrap for the demo PF (stock image, no data.zip): creates the access-token manager,
# the client_credentials access-token mapping, the ssf.manage scope, and the ssf-receiver client — via
# the admin API. Idempotent: re-running skips what already exists.
set -euo pipefail
ADMIN="${PF_ADMIN_BASE:-https://localhost:19999}/pf-admin-api/v1"
PW="${PF_ADMIN_PW:-2FederateM0re}"
CLIENT_SECRET="${SSF_CLIENT_SECRET:-ssf-demo-secret-123}"
A() { curl -sk -u "administrator:$PW" -H 'X-XSRF-Header: PingFederate' -H 'Content-Type: application/json' "$@"; }

echo "== waiting for the PF admin API =="
# unauthenticated probe — repeated failed Basic auth against a fresh admin account would LOCK it
for i in $(seq 1 60); do
  resp="$(curl -sk -H 'X-XSRF-Header: PingFederate' "$ADMIN/version" || true)"
  [[ "$resp" == *basic_auth_required* || "$resp" == *license_agreement* || "$resp" == *'"version"'* ]] && break
  sleep 5
done
[[ -n "${resp:-}" ]] || { echo "admin API never came up ($ADMIN)"; exit 1; }
echo "   admin API up"

echo "== first-run gates: license agreement + initial admin =="
# (The image ships hook 83-configure-admin for this, but nothing invokes it in STANDALONE mode —
#  so do exactly what it would: accept the agreement, then create the administrator.)
if [[ "$resp" == *license_agreement* ]]; then
  curl -sk -X PUT -H 'X-XSRF-Header: PingFederate' -H 'Content-Type: application/json' \
    -d '{"accepted": true}' "$ADMIN/license/agreement" >/dev/null
  echo "   agreement accepted"
fi
if A "$ADMIN/version" | grep -q invalid_credentials; then
  curl -sk -X POST -H 'X-XSRF-Header: PingFederate' -H 'Content-Type: application/json' -d '{
    "username": "administrator", "password": "'"$PW"'",
    "description": "Initial administrator user.", "auditor": false, "active": true,
    "roles": ["ADMINISTRATOR","USER_ADMINISTRATOR","CRYPTO_ADMINISTRATOR","EXPRESSION_ADMINISTRATOR","DATA_COLLECTION_ADMINISTRATOR"]
  }' "$ADMIN/administrativeAccounts" >/dev/null
  echo "   administrator created"
fi
A "$ADMIN/version" | grep -q '"version"' && echo "   admin API authenticated" \
  || { echo "   FAILED: admin API still not usable"; exit 1; }

echo "== access token manager demoATM (reference tokens) =="
if A "$ADMIN/oauth/accessTokenManagers/demoATM" | grep -q '"id":"demoATM"'; then
  echo "   exists"
else
  A -X POST "$ADMIN/oauth/accessTokenManagers" -d '{
    "id": "demoATM", "name": "demoATM",
    "pluginDescriptorRef": {"id": "org.sourceid.oauth20.token.plugin.impl.ReferenceBearerAccessTokenManagementPlugin"},
    "configuration": {"fields": []},
    "attributeContract": {"extendedAttributes": [{"name": "sub"}]}
  }' | grep -q '"id":"demoATM"' && echo "   created" || { echo "   FAILED"; exit 1; }
fi

echo "== client_credentials access-token mapping =="
if A "$ADMIN/oauth/accessTokenMappings" | grep -q 'CLIENT_CREDENTIALS|demoATM'; then
  echo "   exists"
else
  A -X POST "$ADMIN/oauth/accessTokenMappings" -d '{
    "context": {"type": "CLIENT_CREDENTIALS"},
    "accessTokenManagerRef": {"id": "demoATM"},
    "attributeContractFulfillment": {"sub": {"source": {"type": "TEXT"}, "value": "ssf-receiver"}}
  }' | grep -q 'CLIENT_CREDENTIALS' && echo "   created" || { echo "   FAILED"; exit 1; }
fi

echo "== scope ssf.manage =="
settings="$(A "$ADMIN/oauth/authServerSettings")"
if echo "$settings" | grep -q '"ssf.manage"'; then
  echo "   exists"
else
  echo "$settings" | python3 -c '
import json,sys
s = json.load(sys.stdin)
s.setdefault("scopes", []).append({"name": "ssf.manage", "description": "SSF stream management (demo)"})
print(json.dumps(s))' | A -X PUT "$ADMIN/oauth/authServerSettings" -d @- | grep -q '"ssf.manage"' \
    && echo "   added" || { echo "   FAILED"; exit 1; }
fi

echo "== client ssf-receiver (client_credentials + introspection) =="
if A "$ADMIN/oauth/clients/ssf-receiver" | grep -q '"clientId":"ssf-receiver"'; then
  echo "   exists"
else
  A -X POST "$ADMIN/oauth/clients" -d '{
    "clientId": "ssf-receiver", "name": "SSF Receiver (demo)", "enabled": true,
    "grantTypes": ["CLIENT_CREDENTIALS", "ACCESS_TOKEN_VALIDATION"],
    "clientAuth": {"type": "SECRET", "secret": "'"$CLIENT_SECRET"'"},
    "restrictScopes": true, "restrictedScopes": ["ssf.manage"],
    "defaultAccessTokenManagerRef": {"id": "demoATM"}
  }' | grep -q '"clientId":"ssf-receiver"' && echo "   created" || { echo "   FAILED"; exit 1; }
fi

echo "== bootstrap complete =="
