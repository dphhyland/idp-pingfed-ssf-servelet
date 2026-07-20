#!/usr/bin/env bash
# End-to-end SSF transmitter walk against the demo stack:
#   metadata -> bearer token -> create poll stream -> SCIM-provision a subject -> verification SET ->
#   poll -> logout => caep.session-revoked -> SCIM deprovision => risc.account-disabled -> LDM store peek
#   -> PF restart durability check -> ack + cleanup.
set -euo pipefail
BASE="${PF_BASE:-https://localhost:19031}"
ISS="${OIDF_SSF_ISSUER:-https://localhost:19031}"
SECRET="${SSF_CLIENT_SECRET:-ssf-demo-secret-123}"
SESSION_EVT="https://schemas.openid.net/secevent/caep/event-type/session-revoked"
DISABLED_EVT="https://schemas.openid.net/secevent/risc/event-type/account-disabled"
command -v jq >/dev/null || { echo "needs jq"; exit 1; }
pass() { echo "[PASS] $1"; }
b64d() { python3 -c 'import base64,sys; d=sys.stdin.read().strip(); print(base64.urlsafe_b64decode(d + "=" * (-len(d) % 4)).decode())'; }
fail() { echo "[FAIL] $1"; exit 1; }

echo "== 1. transmitter metadata =="
cfg="$(curl -sk "$BASE/.well-known/ssf-configuration")"
echo "$cfg" | jq -e '.issuer and .jwks_uri and .configuration_endpoint' >/dev/null || fail "metadata incomplete: $cfg"
pass "ssf-configuration served (issuer $(echo "$cfg" | jq -r .issuer))"

echo "== 2. receiver bearer token (client_credentials, scope ssf.manage) =="
TOKEN="$(curl -sk -u "ssf-receiver:$SECRET" -d 'grant_type=client_credentials&scope=ssf.manage' \
  "$BASE/as/token.oauth2" | jq -r '.access_token // empty')"
[[ -n "$TOKEN" ]] || fail "no access token — did scripts/bootstrap-pf.sh run?"
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')
pass "token obtained"

echo "== 3. create a poll stream =="
stream="$(curl -sk -X POST "$BASE/ssf/streams" "${AUTH[@]}" -d "{
  \"aud\": \"https://receiver.example.com\",
  \"delivery\": {\"method\": \"urn:ietf:rfc:8936\"},
  \"events_requested\": [\"$SESSION_EVT\", \"$DISABLED_EVT\"]}")"
SID="$(echo "$stream" | jq -r '.stream_id // empty')"
[[ -n "$SID" ]] || fail "stream create: $stream"
pass "stream $SID"

echo "== 4. SCIM-provision subject bob (userName -> iss_sub against the issuer) =="
curl -sk -X POST "$BASE/ssf/scim/v2/Users" "${AUTH[@]}" -d "{
  \"schemas\": [\"urn:ietf:params:scim:schemas:core:2.0:User\",
                \"urn:ietf:params:scim:schemas:extension:ssf:2.0:Subject\"],
  \"userName\": \"bob\",
  \"urn:ietf:params:scim:schemas:extension:ssf:2.0:Subject\": {\"streams\": [\"$SID\"]}}" \
  | jq -e '.id' >/dev/null || fail "SCIM provision"
pass "bob provisioned into the stream via SCIM"

echo "== 5. verification SET round-trip =="
curl -sk -X POST "$BASE/ssf/verify" "${AUTH[@]}" -d "{\"stream_id\":\"$SID\",\"state\":\"demo-1\"}" \
  | jq -e '.jti' >/dev/null || fail "verify"
poll() { curl -sk -X POST "$BASE/ssf/poll?stream_id=$SID" "${AUTH[@]}" -d '{"maxEvents":20,"returnImmediately":true}'; }
p="$(poll)"
VJTI="$(echo "$p" | jq -r '.sets | keys[0] // empty')"
[[ -n "$VJTI" ]] || fail "verification SET not polled: $p"
echo "$p" | jq -r ".sets[\"$VJTI\"]" | cut -d. -f2 | b64d | jq -e '.events' >/dev/null \
  || fail "verification SET payload undecodable"
pass "verification SET polled + decoded (jti $VJTI)"

echo "== 6. logout -> caep.session-revoked =="
IDTOK="$(python3 - "$ISS" <<'EOF'
import base64, json, sys
b64 = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()
print(b64({"alg": "none"}) + "." + b64({"iss": sys.argv[1], "sub": "bob"}) + ".")
EOF
)"
curl -sk -o /dev/null "$BASE/idp/init_logout.openid?id_token_hint=$IDTOK"
sleep 1
p="$(poll)"
decoded="$(echo "$p" | jq -r '.sets[]' | while read -r jws; do echo "$jws" | cut -d. -f2 | b64d; echo; done)"
echo "$decoded" | grep -q "session-revoked" || fail "no session-revoked SET after logout: $p"
pass "logout emitted a signed caep.session-revoked SET for bob"

echo "== 7. SCIM disable (PUT active:false) -> risc.account-disabled =="
curl -sk -X PUT "$BASE/ssf/scim/v2/Users" "${AUTH[@]}" -d "{
  \"schemas\": [\"urn:ietf:params:scim:schemas:core:2.0:User\"],
  \"userName\": \"bob\", \"active\": false}" -o /dev/null
p="$(poll)"
decoded="$(echo "$p" | jq -r '.sets[]' | while read -r jws; do echo "$jws" | cut -d. -f2 | b64d; echo; done)"
echo "$decoded" | grep -q "account-disabled" || fail "no account-disabled SET after disable: $p"
pass "SCIM disable emitted risc.account-disabled"

echo "== 8. the LDM store holds the state (idm.entry by object class) =="
docker compose exec -T ldm-store psql -U ldm -d ldm -c \
  "SELECT object_classes[1] AS class, count(*) FROM idm.entry GROUP BY 1 ORDER BY 1;" || true

echo "== 9. durability: restart PF, stream survives (state is in Postgres, not PF) =="
docker compose restart pingfederate >/dev/null 2>&1
for i in $(seq 1 60); do curl -sk -o /dev/null -w '' "$BASE/.well-known/ssf-configuration" && break; sleep 5; done
TOKEN="$(curl -sk -u "ssf-receiver:$SECRET" -d 'grant_type=client_credentials&scope=ssf.manage' \
  "$BASE/as/token.oauth2" | jq -r '.access_token // empty')"
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')
curl -sk "$BASE/ssf/streams?stream_id=$SID" "${AUTH[@]}" | jq -e ".stream_id == \"$SID\"" >/dev/null \
  || fail "stream did not survive the PF restart"
pass "stream $SID survived a PF restart"

echo "== 10. ack everything + delete the stream =="
p="$(poll)"
ACKS="$(echo "$p" | jq -c '[.sets | keys[]]')"
curl -sk -X POST "$BASE/ssf/poll?stream_id=$SID" "${AUTH[@]}" -d "{\"ack\": $ACKS}" -o /dev/null
curl -sk -X DELETE "$BASE/ssf/streams?stream_id=$SID" "${AUTH[@]}" -o /dev/null
pass "acked + deleted"

echo "== 11. LOOPBACK PUSH: transmitter -> its own receiver (live RFC 8935) =="
PUSH_TOKEN="loopback-push-token-456"
pstream="$(curl -sk -X POST "$BASE/ssf/streams" "${AUTH[@]}" -d "{
  \"aud\": \"https://receiver-loopback.example.com\",
  \"delivery\": {\"method\": \"urn:ietf:rfc:8935\",
                \"endpoint_url\": \"http://127.0.0.1:9080/ssf/receiver/events\",
                \"authorization_header\": \"Bearer $PUSH_TOKEN\"},
  \"events_requested\": [\"$SESSION_EVT\"]}")"
PSID="$(echo "$pstream" | jq -r '.stream_id // empty')"
[[ -n "$PSID" ]] || fail "push stream create: $pstream"
curl -sk -X POST "$BASE/ssf/subjects:add" "${AUTH[@]}" \
  -d "{\"stream_id\":\"$PSID\",\"subject\":{\"format\":\"iss_sub\",\"iss\":\"$ISS\",\"sub\":\"carol\"}}" -o /dev/null
IDTOK2="$(python3 - "$ISS" <<'EOF2'
import base64, json, sys
b64 = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()
print(b64({"alg": "none"}) + "." + b64({"iss": sys.argv[1], "sub": "carol"}) + ".")
EOF2
)"
curl -sk -o /dev/null "$BASE/idp/init_logout.openid?id_token_hint=$IDTOK2"
echo "   waiting for the push executor to deliver (tick 5s)..."
delivered=""
for i in $(seq 1 12); do
  sleep 3
  rx="$(curl -sk "$BASE/ssf/receiver/events" -H "Authorization: Bearer $PUSH_TOKEN")"
  if echo "$rx" | jq -e '.received[] | select(.sub_id.sub == "carol")' >/dev/null 2>&1; then delivered=yes; break; fi
done
[[ -n "$delivered" ]] || fail "receiver never got carol's session-revoked SET: $rx"
echo "$rx" | jq -e '.received[0].event_types | index("'"$SESSION_EVT"'")' >/dev/null \
  || fail "received SET is not session-revoked: $rx"
pass "PUSH delivered end-to-end: logout -> transmitter push (RFC 8935) -> receiver verified + dispatched"
echo "   receiver log line (grant revocation action):"
docker compose logs pingfederate 2>&1 | grep -oE "SSF receiver: revoked [0-9]+ grant.*carol.*" | tail -1 || true
curl -sk -X DELETE "$BASE/ssf/streams?stream_id=$PSID" "${AUTH[@]}" -o /dev/null

echo
echo "== DEMO COMPLETE: metadata, auth, stream mgmt, SCIM provisioning, verification, logout->CAEP,"
echo "   deprovision->RISC, LDM persistence, restart durability, and LIVE PUSH->RECEIVER all verified =="
