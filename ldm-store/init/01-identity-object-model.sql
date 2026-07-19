-- Identity Object Model — Postgres realisation
-- Draft v0.3 — ID Partners
-- Companion to identity-object-model.md
-- Requires Postgres 14+ (tested against 16)

BEGIN;

CREATE SCHEMA IF NOT EXISTS idm;

-- ---------------------------------------------------------------------------
-- Controlled vocabularies (enum where stable, lookup table where scheme-owned)
-- ---------------------------------------------------------------------------

CREATE TYPE idm.record_status AS ENUM
  ('active','revoked','expired','superseded','suspended');

CREATE TYPE idm.subject_type AS ENUM
  ('person','agent','organisation','workload');

-- Scheme-owned vocabularies change with the trust framework, so: table not enum
CREATE TABLE idm.vocabulary (
  vocab       text NOT NULL,          -- e.g. 'documentType', 'consentType', 'rarType'
  code        text NOT NULL,          -- e.g. 'passport_au'
  scheme      text NOT NULL DEFAULT 'default',
  label       text,
  meta        jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (vocab, code, scheme)
);

-- ---------------------------------------------------------------------------
-- The entry table — LDAP backend, translated
-- ---------------------------------------------------------------------------

CREATE TABLE idm.entry (
  entry_uuid       uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- objectClass values; exactly one structural class enforced by trigger
  object_classes   text[] NOT NULL,

  -- hot real columns (every query path touches these)
  subject_id       text,
  subject_type     idm.subject_type,
  parent_id        uuid REFERENCES idm.entry(entry_uuid) ON DELETE CASCADE,
  record_status    idm.record_status NOT NULL DEFAULT 'active',
  scheme_context   text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  modified_at      timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz,

  -- everything else
  attrs            jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- generated equality-lookup keys (the dsconfig create-local-db-index set)
  client_id        text GENERATED ALWAYS AS (attrs->>'clientId') STORED,
  grant_guid       text GENERATED ALWAYS AS (attrs->>'grantGuid') STORED,
  correlation_id   text GENERATED ALWAYS AS (attrs->>'correlationId') STORED,
  hashed_refresh   text GENERATED ALWAYS AS (attrs->>'hashedRefreshTokenValue') STORED
);

-- Indexes: the PF grant-storage index set, plus JSONB path ops
CREATE INDEX entry_object_classes_gin ON idm.entry USING gin (object_classes);
CREATE INDEX entry_attrs_gin          ON idm.entry USING gin (attrs jsonb_path_ops);
CREATE INDEX entry_subject_idx        ON idm.entry (subject_id) WHERE subject_id IS NOT NULL;
CREATE INDEX entry_parent_idx         ON idm.entry (parent_id)  WHERE parent_id IS NOT NULL;
CREATE INDEX entry_client_idx         ON idm.entry (client_id)  WHERE client_id IS NOT NULL;
CREATE UNIQUE INDEX entry_grant_guid_uq ON idm.entry (grant_guid) WHERE grant_guid IS NOT NULL;
CREATE INDEX entry_hashed_refresh_idx ON idm.entry (hashed_refresh) WHERE hashed_refresh IS NOT NULL;
CREATE INDEX entry_correlation_idx    ON idm.entry (correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX entry_expiry_idx         ON idm.entry (expires_at) WHERE expires_at IS NOT NULL;
CREATE INDEX entry_status_idx         ON idm.entry (record_status) WHERE record_status <> 'active';

-- ---------------------------------------------------------------------------
-- Class registry: structural/abstract/auxiliary + MUST attributes
-- ---------------------------------------------------------------------------

CREATE TABLE idm.object_class (
  name        text PRIMARY KEY,
  ldap_name   text UNIQUE,             -- canonical LDAP/LDIF class name
  kind        text NOT NULL CHECK (kind IN ('abstract','structural','auxiliary')),
  sup         text REFERENCES idm.object_class(name),
  must_attrs  text[] NOT NULL DEFAULT '{}',
  may_attrs   text[] NOT NULL DEFAULT '{}'
);

-- v0.2 classes (this model) — OID assignments per §10.3 of the design doc
INSERT INTO idm.object_class (name, ldap_name, kind, sup, must_attrs) VALUES
 ('identityObject',NULL,'abstract',NULL,'{}'),
 ('oauthClientRegistration','ldm-3020-client','structural','identityObject','{clientId,clientStatus,tokenEndpointAuthMethod}'),
 ('oauthGrant','ldm-2200-oauth-grant','structural','identityObject','{grantGuid,clientId,grantType,issuedTimestamp}'),
 ('agentDelegation','ldm-2210-agent-delegation','auxiliary',NULL,'{principalId,agentId}'),
 ('authorisationRecord','ldm-6000-authorisation-record','abstract','identityObject','{eventTimestamp,outcome}'),
 ('consentRecord','ldm-6100-consent','structural','authorisationRecord','{consentType,purpose,presentedArtefactHash}'),
 ('intentRecord','ldm-6200-intent','structural','authorisationRecord','{intentType,challenge,challengeHash}'),
 ('protectedResourceAuthorisation','ldm-6300-resource-authorisation','structural','authorisationRecord','{grantRef,resourceIdentifier}'),
 ('authenticationEvent','ldm-6400-authentication-event','structural','authorisationRecord','{acr,amr}'),
 ('identityProofingRecord','ldm-6500-identity-proofing','structural','authorisationRecord','{proofingScheme,ipLevelAchieved}'),
 ('identityEvidence','ldm-7000-identity-evidence','abstract','identityObject','{evidenceCategory,verificationMethod,verificationResult}'),
 ('documentEvidence','ldm-7100-document-evidence','structural','identityEvidence','{documentType,issuingAuthority}'),
 ('verifiablePresentationEvidence','ldm-7200-vp-evidence','structural','identityEvidence','{presentationFormat,credentialType,credentialIssuer}'),
 ('biometricBindingEvidence','ldm-7300-biometric-binding-evidence','structural','identityEvidence','{matchTargetRef,matchResult}'),
 ('dataSourceEvidence','ldm-7400-data-source-evidence','structural','identityEvidence','{sourceType,sourceName}'),
 -- v0.3: post-quantum crypto agility layer (see docs 06-post-quantum.md)
 ('cryptoBinding','ldm-8000-crypto-binding','auxiliary',NULL,'{pqPosture}');

-- Hackberry classes (pip/idp/schemas/*.ldif), loaded into the same registry
INSERT INTO idm.object_class (name, ldap_name, kind, sup, must_attrs) VALUES
 ('identity','ldm-1000-identity','structural',NULL,'{cn,identityID,identityType,identityDescriptor,internalKey}'),
 ('involvedParty','ldm-4200-involved-party','structural','identity','{}'),
 ('entitlement','ldm-2100-entitlement','structural',NULL,'{uuid}'),
 ('structuralEntitlement','ldm-2110-structural-entitlement','auxiliary',NULL,'{identity,toInvolvedParty,aal}'),
 ('channelEntitlement','ldm-2130-channel-entitlement','auxiliary',NULL,'{application,serviceRole,serviceUser}'),
 ('role','ldm-3000-role','structural',NULL,'{uuid,cn}'),
 ('businessRole','ldm-3100-business-role','structural','role','{aal,fromInvolvedParty,toInvolvedParty}'),
 ('serviceRole','ldm-3200-service-role','structural','role','{predicate}'),
 ('resourceRole','ldm-3500-resource-role','structural','role','{fromInvolvedParty,resource,aal}'),
 ('channel','ldm-3010-channel','structural',NULL,'{uuid,cn,channelType}'),
 ('application','ldm-3030-application','structural',NULL,'{uuid,cn}'),
 ('serviceProfile','ldm-3300-service-profile','structural',NULL,'{uuid,cn}'),
 ('serviceUser','ldm-3400-service-user','auxiliary',NULL,'{}'),
 ('resource','ldm-5000-resource','structural',NULL,'{uuid}'),
 ('account','ldm-5200-account','structural','resource','{}'),
 ('card','ldm-5210-card','structural','account','{}'),
 ('externalEntry','ldm-0100-external-entry','auxiliary',NULL,'{externalSystem,externalSystemID,href}'),
 ('relatedInvolvedParty','ldm-0200-related-involved-party','auxiliary',NULL,'{}');

-- ---------------------------------------------------------------------------
-- Invariant triggers
-- ---------------------------------------------------------------------------

-- 1) exactly one most-subordinate structural class; MUST attributes enforced
--    up the full SUP chain (entries may list their whole superior chain, LDAP-style;
--    accepts both storage names and canonical ldm-* names)
CREATE OR REPLACE FUNCTION idm.check_entry_classes() RETURNS trigger AS $$
DECLARE
  resolved text[];
  leaf_count int;
  missing text;
BEGIN
  -- resolve ldm-* aliases to storage names
  SELECT array_agg(oc.name) INTO resolved
    FROM idm.object_class oc
   WHERE oc.name = ANY (NEW.object_classes) OR oc.ldap_name = ANY (NEW.object_classes);

  IF resolved IS NULL OR array_length(resolved,1) < array_length(NEW.object_classes,1) THEN
    RAISE EXCEPTION 'unknown objectClass in %', NEW.object_classes;
  END IF;

  -- a structural class is a leaf unless it is an ancestor of another present structural class
  WITH RECURSIVE present AS (
    SELECT name FROM idm.object_class WHERE name = ANY (resolved) AND kind = 'structural'
  ), anc AS (
    SELECT p.name AS leaf, oc.sup AS ancestor
      FROM present p JOIN idm.object_class oc ON oc.name = p.name
    UNION ALL
    SELECT a.leaf, oc.sup
      FROM anc a JOIN idm.object_class oc ON oc.name = a.ancestor
     WHERE oc.sup IS NOT NULL
  )
  SELECT count(*) INTO leaf_count
    FROM present p
   WHERE p.name NOT IN (SELECT ancestor FROM anc WHERE ancestor IS NOT NULL);

  IF leaf_count <> 1 THEN
    RAISE EXCEPTION 'entry must have exactly one most-subordinate structural objectClass, found %', leaf_count;
  END IF;

  -- MUST attributes: every listed class plus every ancestor of every listed class
  WITH RECURSIVE chain AS (
    SELECT name, sup FROM idm.object_class WHERE name = ANY (resolved)
    UNION
    SELECT oc.name, oc.sup FROM chain c JOIN idm.object_class oc ON oc.name = c.sup
  )
  SELECT a.attr INTO missing
    FROM chain ch
    JOIN idm.object_class oc ON oc.name = ch.name,
    unnest(oc.must_attrs) AS a(attr)
   WHERE NOT (NEW.attrs ? a.attr)
   LIMIT 1;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'missing MUST attribute % for objectClasses %', missing, NEW.object_classes;
  END IF;

  NEW.object_classes := resolved;
  NEW.modified_at := now();
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER entry_class_check
  BEFORE INSERT OR UPDATE ON idm.entry
  FOR EACH ROW EXECUTE FUNCTION idm.check_entry_classes();

-- 2) biometric binding requires a biometric-collection consent
CREATE OR REPLACE FUNCTION idm.check_biometric_consent() RETURNS trigger AS $$
BEGIN
  IF 'biometricBindingEvidence' = ANY (NEW.object_classes) THEN
    IF NEW.attrs->>'consentRef' IS NULL THEN
      RAISE EXCEPTION 'biometricBindingEvidence requires consentRef';
    END IF;
    PERFORM 1 FROM idm.entry c
     WHERE c.entry_uuid = (NEW.attrs->>'consentRef')::uuid
       AND 'consentRecord' = ANY (c.object_classes)
       AND c.attrs->>'consentType' = 'biometric_collection'
       AND c.record_status = 'active';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'consentRef must resolve to an active biometric_collection consentRecord';
    END IF;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER entry_biometric_consent_check
  BEFORE INSERT OR UPDATE ON idm.entry
  FOR EACH ROW EXECUTE FUNCTION idm.check_biometric_consent();

-- ---------------------------------------------------------------------------
-- Typed views (application-facing shapes)
-- ---------------------------------------------------------------------------

CREATE VIEW idm.v_oauth_grant AS
SELECT entry_uuid, subject_id, record_status, created_at, expires_at,
       grant_guid,
       client_id,
       attrs->>'grantType'                    AS grant_type,
       attrs->>'scope'                        AS scope,
       attrs->'authorizationDetails'          AS authorization_details,
       attrs->>'consentRef'                   AS consent_ref,
       attrs->>'entitlementRef'               AS entitlement_ref,
       attrs->'resourceAuthorisationRefs'     AS resource_authorisation_refs,
       ('agentDelegation' = ANY (object_classes)) AS is_agent_delegation,
       attrs->>'principalId'                  AS principal_id,
       attrs->>'agentId'                      AS agent_id,
       attrs->>'agentOperatorId'              AS agent_operator_id,
       attrs->'actorChain'                    AS actor_chain,
       attrs->'delegationCeiling'             AS delegation_ceiling
FROM idm.entry WHERE 'oauthGrant' = ANY (object_classes);

CREATE VIEW idm.v_client_registration AS
SELECT entry_uuid, record_status, created_at,
       client_id,
       attrs->>'clientName'                   AS client_name,
       attrs->>'tokenEndpointAuthMethod'      AS token_endpoint_auth_method,
       attrs->'redirectUris'                  AS redirect_uris,
       attrs->'grantTypes'                    AS grant_types,
       attrs->>'scope'                        AS scope,
       attrs->'authorizationDetailsTypes'     AS authorization_details_types,
       attrs->>'registrationType'             AS registration_type,
       attrs->>'entityId'                     AS entity_id
FROM idm.entry WHERE 'oauthClientRegistration' = ANY (object_classes);

CREATE VIEW idm.v_consent_record AS
SELECT entry_uuid, subject_id, parent_id, record_status, created_at, expires_at,
       attrs->>'consentType'                  AS consent_type,
       attrs->>'purpose'                      AS purpose,
       attrs->>'presentedArtefactHash'        AS presented_artefact_hash,
       attrs->'dataClusters'                  AS data_clusters,
       attrs->>'counterpartyId'               AS counterparty_id,
       attrs->>'withdrawnTimestamp'           AS withdrawn_at,
       attrs->>'outcome'                      AS outcome
FROM idm.entry WHERE 'consentRecord' = ANY (object_classes);

CREATE VIEW idm.v_intent_record AS
SELECT entry_uuid, subject_id, parent_id, created_at,
       attrs->>'intentType'                   AS intent_type,
       attrs->>'challenge'                    AS challenge,
       attrs->>'challengeHash'                AS challenge_hash,
       attrs->>'responseSignature'            AS response_signature,
       attrs->>'boundTransactionHash'         AS bound_transaction_hash,
       attrs->'derivedIntent'                 AS derived_intent,
       attrs->>'outcome'                      AS outcome
FROM idm.entry WHERE 'intentRecord' = ANY (object_classes);

CREATE VIEW idm.v_resource_authorisation AS
SELECT entry_uuid, subject_id, parent_id, record_status, created_at,
       attrs->>'grantRef'                     AS grant_ref,
       attrs->>'resourceIdentifier'           AS resource_identifier,
       attrs->'actions'                       AS actions,
       attrs->'authorizationDetail'           AS authorization_detail,
       attrs->'constraints'                   AS constraints,
       attrs->>'notBefore'                    AS not_before,
       attrs->>'notAfter'                     AS not_after
FROM idm.entry WHERE 'protectedResourceAuthorisation' = ANY (object_classes);

CREATE VIEW idm.v_authentication_event AS
SELECT entry_uuid, subject_id, created_at,
       attrs->>'acr'                          AS acr,
       attrs->'amr'                           AS amr,
       attrs->>'authenticatorType'            AS authenticator_type,
       attrs->>'aaguid'                       AS aaguid,
       attrs->>'authenticationLevel'          AS authentication_level,
       attrs->>'stepUpFrom'                   AS step_up_from,
       attrs->>'stepUpReason'                 AS step_up_reason,
       attrs->>'outcome'                      AS outcome
FROM idm.entry WHERE 'authenticationEvent' = ANY (object_classes);

CREATE VIEW idm.v_identity_proofing AS
SELECT entry_uuid, subject_id, record_status, created_at,
       attrs->>'proofingScheme'               AS proofing_scheme,
       attrs->>'ipLevelAchieved'              AS ip_level_achieved,
       attrs->>'proofingType'                 AS proofing_type,
       attrs->>'ispId'                        AS isp_id,
       attrs->'evidenceRefs'                  AS evidence_refs,
       attrs->'attributesProofed'             AS attributes_proofed,
       attrs->>'nextReproofDue'               AS next_reproof_due,
       attrs->>'outcome'                      AS outcome
FROM idm.entry WHERE 'identityProofingRecord' = ANY (object_classes);

CREATE VIEW idm.v_identity_evidence AS
SELECT entry_uuid, subject_id, parent_id, created_at,
       (SELECT oc FROM unnest(object_classes) oc
         WHERE oc IN ('documentEvidence','verifiablePresentationEvidence',
                      'biometricBindingEvidence','dataSourceEvidence')
         LIMIT 1)                             AS evidence_class,
       attrs->>'evidenceCategory'             AS evidence_category,
       attrs->>'verificationMethod'           AS verification_method,
       attrs->>'verificationResult'           AS verification_result,
       attrs->>'documentType'                 AS document_type,
       attrs->>'presentationFormat'           AS presentation_format,
       attrs->>'credentialIssuer'             AS credential_issuer,
       attrs->>'matchResult'                  AS match_result
FROM idm.entry WHERE 'identityEvidence' = ANY (object_classes)
   OR object_classes && ARRAY['documentEvidence','verifiablePresentationEvidence',
                              'biometricBindingEvidence','dataSourceEvidence'];

CREATE VIEW idm.v_crypto_inventory AS
SELECT
  (SELECT oc FROM unnest(object_classes) oc
    WHERE oc NOT IN ('cryptoBinding','agentDelegation') LIMIT 1) AS record_class,
  coalesce(attrs->>'pqPosture','classical(unrecorded)')          AS pq_posture,
  coalesce(attrs->>'sigAlgorithm',
           (SELECT string_agg(s->>'alg','+' ORDER BY s->>'role')
              FROM jsonb_array_elements(attrs->'signatureSet') s))  AS sig_alg,
  attrs->>'verificationPolicy'                                    AS verify_policy,
  attrs->>'kemAlgorithm'                                          AS kem_alg,
  count(*)                                                        AS records,
  count(*) FILTER (WHERE expires_at IS NULL OR expires_at > '2030-12-31') AS crossing_2030,
  count(*) FILTER (WHERE (attrs->>'resignDue')::timestamptz < now())      AS resign_overdue
FROM idm.entry
WHERE record_status = 'active'
GROUP BY 1,2,3,4,5;

-- ---------------------------------------------------------------------------
-- Worked example: Hackberry standing state + runtime authorisation chain
-- ---------------------------------------------------------------------------

-- 0a. the subject as a Hackberry involved party (full superior chain listed, LDAP-style)
INSERT INTO idm.entry (object_classes, subject_id, subject_type, attrs) VALUES
 (ARRAY['identity','involvedParty'], 'sub-principal-42', 'person',
  jsonb_build_object(
    'cn','Pat Example', 'identityID','sub-principal-42', 'identityType','customer',
    'identityDescriptor','retail customer', 'internalKey','CIS-000042',
    'trustLevel','IP2_PLUS', 'iamIPType','individual'));

-- 0b. an account resource and a channel entitlement (standing permission)
INSERT INTO idm.entry (object_classes, subject_id, attrs) VALUES
 (ARRAY['resource','account'], 'sub-principal-42',
  jsonb_build_object('uuid','acc-0007','iamResourceType','account',
                     'accountBSB','062-000','accountNumber','12345678','accountStatus','open'));

INSERT INTO idm.entry (object_classes, subject_id, attrs) VALUES
 (ARRAY['ldm-2100-entitlement','channelEntitlement'], 'sub-principal-42',
  jsonb_build_object(
    'uuid','ent-0100',
    'application','app-payments', 'serviceRole','role-payer', 'serviceUser','sub-principal-42',
    'serviceRoleConstraint','instructedAmount.amount<=500.00',
    'effectiveStartDate', now()));

-- 1. consent to delegate to an agent
INSERT INTO idm.entry (object_classes, subject_id, subject_type, attrs) VALUES
 (ARRAY['consentRecord'], 'sub-principal-42', 'person',
  jsonb_build_object(
    'consentType','agent_delegation',
    'purpose','delegate bill payment up to AUD 500/month',
    'presentedArtefactHash','sha256:aa11...',
    'counterpartyId','agent-operator-acme',
    'eventTimestamp', now(), 'outcome','granted'));

-- 2. the grant itself: RAR + agentDelegation auxiliary, referencing the
--    standing entitlement and the consent that authorised issuance
INSERT INTO idm.entry (object_classes, subject_id, subject_type, expires_at, attrs) VALUES
 (ARRAY['oauthGrant','agentDelegation'], 'sub-principal-42', 'person',
  now() + interval '90 days',
  jsonb_build_object(
    'grantGuid','g-0001',
    'clientId','agent-operator-acme',
    'grantType','urn:ietf:params:oauth:grant-type:token-exchange',
    'issuedTimestamp', now(),
    'scope','bank:payments.initiate',
    'authorizationDetails', jsonb_build_array(jsonb_build_object(
        'type','https://schemas.trustframeworks.com/agentic-banking/v1/domestic_payment_initiation',
        'instructedAmount', jsonb_build_object('currency','AUD','amount','500.00'))),
    'principalId','sub-principal-42',
    'agentId','agent:acme-payer:v2.3',
    'agentOperatorId','agent-operator-acme',
    'entitlementRef',(SELECT entry_uuid::text FROM idm.entry
                       WHERE attrs->>'uuid'='ent-0100' LIMIT 1),
    'consentRef',(SELECT entry_uuid::text FROM idm.entry
                   WHERE attrs->>'consentType'='agent_delegation' LIMIT 1)));

-- 3. a dual-signed intent under the delegation (classical + PQ, policy: both must verify)
INSERT INTO idm.entry (object_classes, subject_id, subject_type, attrs) VALUES
 (ARRAY['intentRecord','cryptoBinding'], 'sub-principal-42', 'person',
  jsonb_build_object(
    'intentType','payment_authorisation',
    'challenge','Pay Jane''s Plumbing $500.00 from account ...890',
    'challengeHash','sha-384:bb22...',
    'responseSignature','...',
    'boundTransactionHash','sha-384:cc33...',
    'eventTimestamp', now(), 'outcome','granted',
    'pqPosture','hybrid',
    'verificationPolicy','all',
    'signatureSet', jsonb_build_array(
       jsonb_build_object('alg','ES256','kty','EC','keyRef','kid:passkey-01','role','primary'),
       jsonb_build_object('alg','ML-DSA-65','kty','AKP','keyRef','kid:passkey-01q','role','alternative')),
    'parentGrant','g-0001'));

-- 3b. a legacy classical intent awaiting countersignature — the resign sweep's customer
INSERT INTO idm.entry (object_classes, subject_id, subject_type, attrs) VALUES
 (ARRAY['intentRecord','cryptoBinding'], 'sub-principal-42', 'person',
  jsonb_build_object(
    'intentType','payment_authorisation',
    'challenge','Pay ACME Utilities $120.00 from account ...890',
    'challengeHash','sha256:dd44...',
    'eventTimestamp', now(), 'outcome','granted',
    'pqPosture','classical',
    'sigAlgorithm','ES256',
    'keyKty','EC',
    'resignDue','2028-12-31T00:00:00Z',
    'parentGrant','g-0001'));

COMMIT;

-- Retention sweeps (run from cron / pg_cron):
--   UPDATE idm.entry SET record_status='expired'
--    WHERE expires_at < now() AND record_status='active';
--   SELECT ... WHERE attrs->>'destructionDue' < now()::text;  -- biometric destruction
--   SELECT ... WHERE attrs->>'nextReproofDue' < now()::text;  -- five-year reproof clock
--   SELECT ... WHERE (attrs->>'resignDue')::timestamptz < now();  -- PQ re-sign / archive-timestamp
--   SELECT * FROM idm.v_crypto_inventory ORDER BY crossing_2030 DESC;  -- LATICE locate/assess
