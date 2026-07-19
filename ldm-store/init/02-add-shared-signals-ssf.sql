-- 0001-add-shared-signals-ssf
--
-- Shared Signals (SSF 1.0 / CAEP / RISC) transmitter state in the Identity Object Model.
-- Adds three object classes so the pf-oidf-modules SSF transmitter can persist its state in THIS
-- store (via its LdmSsfStore), instead of private relational tables:
--
--   ssfStream         (structural, ldm-9100) — a receiver's event-stream registration. One entry per
--                      stream; the transmitter-assigned stream id IS the entry_uuid (streams are minted
--                      as UUIDs), so lookup is by primary key and no extra index is needed.
--   ssfStreamSubject  (structural, ldm-9110) — stream membership by containment: one entry per
--                      (stream, subject), parent_id = the stream entry (ON DELETE CASCADE gives
--                      stream-delete cleanup for free). subject_id carries the RFC 9493 canonical key
--                      (e.g. 'email:alice@example.com') — the same subject_id used by grants and
--                      authorisation records, so a stream subject joins to the identity's other state.
--   ssfPendingSet     (structural, ldm-9120) — one undelivered/unacked Security Event Token, also
--                      contained under its stream. expires_at (hot column, already indexed) drives
--                      TTL eviction; delivery retry state lives in attrs.
--
-- Authored outside the ldm-copilot session (MCP server not connected); run through test_migration
-- before applying to any real directory, per the repo workflow.

BEGIN;

-- ---------------------------------------------------------------------------
-- Object classes
-- ---------------------------------------------------------------------------

INSERT INTO idm.object_class (name, ldap_name, kind, sup, must_attrs, may_attrs) VALUES
 ('ssfStream','ldm-9100-ssf-stream','structural','identityObject',
  '{audience,deliveryMethod,streamStatus}',
  '{pushEndpointUrl,pushAuthorizationHeader,eventsRequested,eventsDelivered,statusReason,ssfIssuer}'),
 ('ssfStreamSubject','ldm-9110-ssf-stream-subject','structural','identityObject',
  '{subjectFormat,subjectJson}',
  '{}'),
 ('ssfPendingSet','ldm-9120-ssf-pending-set','structural','identityObject',
  '{jti,setJws,issuedAt}',
  '{eventType,subjectKey,deliveryAttempts,nextAttemptAt}');

-- ---------------------------------------------------------------------------
-- Vocabularies (scheme-owned code lists, per the vocabulary-table pattern)
-- ---------------------------------------------------------------------------

INSERT INTO idm.vocabulary (vocab, code, label) VALUES
 ('ssfDeliveryMethod','urn:ietf:rfc:8935','SET push delivery (RFC 8935)'),
 ('ssfDeliveryMethod','urn:ietf:rfc:8936','SET poll delivery (RFC 8936)'),
 ('ssfStreamStatus','enabled','Stream delivers events'),
 ('ssfStreamStatus','paused','Delivery suspended; configuration and queue retained'),
 ('ssfStreamStatus','disabled','Stream inert until re-enabled'),
 ('ssfEventType','https://schemas.openid.net/secevent/caep/event-type/session-revoked','CAEP session revoked'),
 ('ssfEventType','https://schemas.openid.net/secevent/caep/event-type/credential-change','CAEP credential change'),
 ('ssfEventType','https://schemas.openid.net/secevent/caep/event-type/assurance-level-change','CAEP assurance-level change'),
 ('ssfEventType','https://schemas.openid.net/secevent/risc/event-type/account-disabled','RISC account disabled'),
 ('ssfEventType','https://schemas.openid.net/secevent/risc/event-type/account-enabled','RISC account enabled'),
 ('ssfEventType','https://schemas.openid.net/secevent/ssf/event-type/verification','SSF verification');

-- ---------------------------------------------------------------------------
-- Queue-path indexes (partial: only ssfPendingSet rows)
-- ---------------------------------------------------------------------------
-- The push executor scans for due SETs (nextAttemptAt <= now, oldest first) and acks by (stream, jti);
-- neither is served by the existing GIN containment index, so give each an expression index scoped to
-- the pending-set class. Stream membership checks use the existing entry_parent_idx + entry_subject_idx.

CREATE INDEX entry_ssf_pending_due_idx
    ON idm.entry (((attrs->>'nextAttemptAt')::bigint))
 WHERE 'ssfPendingSet' = ANY (object_classes);

CREATE INDEX entry_ssf_pending_order_idx
    ON idm.entry (((attrs->>'issuedAt')::bigint))
 WHERE 'ssfPendingSet' = ANY (object_classes);

CREATE INDEX entry_ssf_pending_jti_idx
    ON idm.entry ((attrs->>'jti'))
 WHERE 'ssfPendingSet' = ANY (object_classes);

COMMIT;
