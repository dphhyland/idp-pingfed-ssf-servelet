-- 03 = record the Identity Object Model ledger for what 01 and 02 just built.
--
-- 01 and 02 build the model straight from the spec SQL, so idm.schema_migration has no rows
-- saying 0000-base-schema and 0001-add-shared-signals-ssf are here. pf-agentic-identity 0.7.0+
-- holds an ldm SSF store to that ledger by name and refuses a database without them
-- (FAILED_CONFIG at start-up). Record mode writes a row only for a migration whose
-- effect is fully present; it never applies one.
--
-- Below the SET: idp-scim-service scripts/reconcile-ledger.sql, verbatim, from its main at
-- e9652bd. Refresh it from there when the model adds a migration.

SET ldm.reconcile_mode = 'record';

-- Reconcile a directory's migration ledger with what the database actually has.
--
-- A directory built some other way than by applying migrations/ in order — straight from
-- spec/identity-object-model.sql, or from docker-entrypoint-initdb.d scripts — has the
-- migrations' EFFECTS but no rows in idm.schema_migration saying so. Anything that holds a
-- database to the ledger by migration name (pf-agentic-identity's IomLedger.require, from
-- 0.7.0) then refuses it. This script closes that gap.
--
-- For every migration in migrations/ it probes the catalog, read-only, and reports one of:
--
--   recorded   the ledger already has it, with the file's checksum
--   present    the effect is fully here but unrecorded  -> record it
--   absent     none of the effect is here               -> apply it (psql -f, below)
--   partial    some of the effect is here               -> neither: investigate by hand
--
-- In report mode (the default) it writes NOTHING. In record mode it inserts a ledger row for
-- each 'present' migration — name and the file's checksum, applied_by marked as recorded —
-- and nothing else. It never applies a migration, never records one that is absent or
-- partial, and never touches a row the ledger already has. Applying what is absent is yours:
-- the report prints the psql commands, in order.
--
--   # 1. report (read-only; a SELECT-only role is enough)
--   psql "$DSN" -v ON_ERROR_STOP=1 -f scripts/reconcile-ledger.sql
--
--   # 2. record what is present (needs CREATE on idm + INSERT on idm.schema_migration)
--   PGOPTIONS='-c ldm.reconcile_mode=record' psql "$DSN" -v ON_ERROR_STOP=1 -f scripts/reconcile-ledger.sql
--
--   # 3. apply what is absent, in the order the report gives, then run 1 again
--
-- In a docker-entrypoint-initdb.d script, put `SET ldm.reconcile_mode = 'record';` before
-- including this file, or run it via a .sh with PGOPTIONS as above.
--
-- The 002/006 hazard: 002-backfill-may-attrs SETS involvedParty's MAY list, so applying it
-- after 006-add-agent-instance-registry drops pingoneUserId. If 002 is absent and 006 is
-- already here, the report says to apply 002 and then re-apply 006 (idempotent; it restores
-- pingoneUserId by union). Never apply 002 alone after 006.
--
-- Keeping it current: every migration under migrations/ must have a row in `migration` below
-- with its file's ldm-checksum, and at least one probe. The e2e suite fails if either drifts.

BEGIN;

DO $reconcile$
DECLARE
  mode     text := lower(coalesce(nullif(current_setting('ldm.reconcile_mode', true), ''), 'report'));
  m        record;
  p        record;
  expr     text;
  ok       boolean;
  passed   int;
  total    int;
  missing  text[];
  ledger   boolean;
  recorded text;
  status   text;
  here     text[] := '{}';   -- migrations whose effect is in this database (present or recorded)
  to_record text[] := '{}';
  record_sums text[] := '{}';  -- checksums, parallel to to_record
  to_apply  text[] := '{}';
  partials  text[] := '{}';
  flagged   text[] := '{}';
BEGIN
  IF mode NOT IN ('report', 'record') THEN
    RAISE EXCEPTION 'ldm.reconcile_mode must be report or record, not %', mode;
  END IF;

  IF to_regclass('idm.entry') IS NULL OR to_regclass('idm.object_class') IS NULL
     OR to_regclass('idm.vocabulary') IS NULL THEN
    RAISE NOTICE 'No Identity Object Model base schema here (idm.entry / object_class / vocabulary). '
                 'Nothing to record. Build it by applying migrations/ in order, from 0000-base-schema.';
    RETURN;
  END IF;

  ledger := to_regclass('idm.schema_migration') IS NOT NULL;

  FOR m IN
    SELECT * FROM (VALUES
      ('0000-base-schema',                'sha256:26b993e9e8d00c4293169f1f358b6113ec3a1507b0f0a828adabc328a7636272'),
      ('0001-add-shared-signals-ssf',     'sha256:52de3c5a95eaaa3ab6f36ac4f8d9f6f0be991c6bf1ce53c917648a992d0e101e'),
      ('002-backfill-may-attrs',          'sha256:f241224c26c136a0605e56138dccef5ef7d18695798e505aac5061620eba8955'),
      ('003-index-resign-due',            'sha256:22ce75084a9e1c5f987a524c566c5e64521b1ac42becd6b5cd16b7f23268e2a4'),
      ('004-index-next-reproof-due',      'sha256:559ada7431ea575840428bacfed0fc3873cfc48701eceabafbd96efd7e2dbb04'),
      ('005-index-destruction-due',       'sha256:28d97917cf15c9b83f08262a2ecff7be879c22fa0a527ae0a124847646bd07e7'),
      ('006-add-agent-instance-registry', 'sha256:70fe5c766118f22e4511f4ed51bb379ff8d8444d340817de2b3bb8938c7db2a9'),
      ('007-add-protocol-state',          'sha256:a5e0f18d2ee5db500d4eaa7635d5ef5d89525e1a6c83d62ecc80be99d072ad28')
    ) AS migration(name, checksum)
  LOOP
    passed := 0; total := 0; missing := '{}';

    -- Probes: (migration, kind, object, arg). Each kind is one catalog question; see the CASE.
    -- The 7 classes 002 leaves at MAY '{}' have no probe — an empty list cannot tell 002 apart
    -- from the spec.
    FOR p IN
      SELECT probe.kind, probe.obj, probe.arg FROM (VALUES
        ('0000-base-schema', 'type',    'record_status', NULL),
        ('0000-base-schema', 'type',    'subject_type',  NULL),
        ('0000-base-schema', 'table',   'entry',         NULL),
        ('0000-base-schema', 'table',   'object_class',  NULL),
        ('0000-base-schema', 'table',   'vocabulary',    NULL),
        ('0000-base-schema', 'index',   'entry_object_classes_gin', NULL),
        ('0000-base-schema', 'index',   'entry_attrs_gin',          NULL),
        ('0000-base-schema', 'index',   'entry_subject_idx',        NULL),
        ('0000-base-schema', 'index',   'entry_parent_idx',         NULL),
        ('0000-base-schema', 'index',   'entry_client_idx',         NULL),
        ('0000-base-schema', 'index',   'entry_grant_guid_uq',      NULL),
        ('0000-base-schema', 'index',   'entry_hashed_refresh_idx', NULL),
        ('0000-base-schema', 'index',   'entry_correlation_idx',    NULL),
        ('0000-base-schema', 'index',   'entry_expiry_idx',         NULL),
        ('0000-base-schema', 'index',   'entry_status_idx',         NULL),
        ('0000-base-schema', 'trigger', 'entry_class_check',             NULL),
        ('0000-base-schema', 'trigger', 'entry_biometric_consent_check', NULL),
        ('0000-base-schema', 'view',    'v_oauth_grant',            NULL),
        ('0000-base-schema', 'view',    'v_client_registration',    NULL),
        ('0000-base-schema', 'view',    'v_consent_record',         NULL),
        ('0000-base-schema', 'view',    'v_intent_record',          NULL),
        ('0000-base-schema', 'view',    'v_resource_authorisation', NULL),
        ('0000-base-schema', 'view',    'v_authentication_event',   NULL),
        ('0000-base-schema', 'view',    'v_identity_proofing',      NULL),
        ('0000-base-schema', 'view',    'v_identity_evidence',      NULL),
        ('0000-base-schema', 'view',    'v_crypto_inventory',       NULL),
        ('0000-base-schema', 'classes', '{identityObject,oauthClientRegistration,oauthGrant,agentDelegation,authorisationRecord,consentRecord,intentRecord,protectedResourceAuthorisation,authenticationEvent,identityProofingRecord,identityEvidence,documentEvidence,verifiablePresentationEvidence,biometricBindingEvidence,dataSourceEvidence,cryptoBinding,identity,involvedParty,entitlement,structuralEntitlement,channelEntitlement,role,businessRole,serviceRole,resourceRole,channel,application,serviceProfile,serviceUser,resource,account,card,externalEntry,relatedInvolvedParty}', NULL),

        ('0001-add-shared-signals-ssf', 'classes', '{ssfStream,ssfStreamSubject,ssfPendingSet}', NULL),
        ('0001-add-shared-signals-ssf', 'index',   'entry_ssf_pending_due_idx',   NULL),
        ('0001-add-shared-signals-ssf', 'index',   'entry_ssf_pending_order_idx', NULL),
        ('0001-add-shared-signals-ssf', 'index',   'entry_ssf_pending_jti_idx',   NULL),
        ('0001-add-shared-signals-ssf', 'vocab',   'ssfDeliveryMethod', NULL),
        ('0001-add-shared-signals-ssf', 'vocab',   'ssfStreamStatus',   NULL),
        ('0001-add-shared-signals-ssf', 'vocab',   'ssfEventType',      NULL),

        ('002-backfill-may-attrs', 'may', 'account', '{accountBSB,accountNumber,accountStatus,productRef,productType}'),
        ('002-backfill-may-attrs', 'may', 'agentDelegation', '{actorChain,agentAttestationRef,agentOperatorId,delegationCeiling,mayAct}'),
        ('002-backfill-may-attrs', 'may', 'application', '{serviceProfile}'),
        ('002-backfill-may-attrs', 'may', 'authenticationEvent', '{aaguid,authenticationLevel,authenticatorType,credentialId,federatedIdpEntityId,freshUntil,stepUpFrom,stepUpReason,userVerification}'),
        ('002-backfill-may-attrs', 'may', 'authorisationRecord', '{channel,deviceRef,evidenceRefs,ipAddress,policyRef,sessionRef,verifierId}'),
        ('002-backfill-may-attrs', 'may', 'biometricBindingEvidence', '{captureChannel,destructionDue,matchAlgorithm,matchScore,matchThreshold,padMethod,padResult,retentionPolicy}'),
        ('002-backfill-may-attrs', 'may', 'card', '{PAN}'),
        ('002-backfill-may-attrs', 'may', 'channelEntitlement', '{serviceProfile,serviceRoleConstraint}'),
        ('002-backfill-may-attrs', 'may', 'consentRecord', '{consentReceiptRef,counterpartyId,dataClusters,durationGranted,durationRequested,lawfulBasis,presentedArtefactUri,withdrawalMethod,withdrawnTimestamp}'),
        ('002-backfill-may-attrs', 'may', 'cryptoBinding', '{archiveTimestampRef,certChainAlgorithms,cryptoPolicyRef,encAlgorithm,hashAlgorithm,hybridComposition,kemAlgorithm,keyKty,keyRef,resignDue,sigAlgorithm,signatureSet,verificationPolicy}'),
        ('002-backfill-may-attrs', 'may', 'dataSourceEvidence', '{matchStrength,matchedAttributes,queryAttributes,screeningLists,screeningResult,sourceTransactionId}'),
        ('002-backfill-may-attrs', 'may', 'documentEvidence', '{chipRead,dobOnDocument,documentExpiry,documentNumberHash,dvsResult,dvsTransactionId,issuingCountry,mrzChecked,nameOnDocument,securityFeaturesChecked}'),
        ('002-backfill-may-attrs', 'may', 'entitlement', '{description,effectiveEndDate,effectiveStartDate}'),
        ('002-backfill-may-attrs', 'may', 'identity', '{lifecycleState,ou,trustLevel}'),
        ('002-backfill-may-attrs', 'may', 'identityEvidence', '{evidenceStrength,rawArtefactRef,sourceIndependence,verificationTimestamp,verifierId}'),
        ('002-backfill-may-attrs', 'may', 'identityObject', '{auditRef,correlationId,parentId,schemeContext,subjectId,subjectType}'),
        ('002-backfill-may-attrs', 'may', 'identityProofingRecord', '{attributesProofed,biometricBindingRef,evidenceRefs,exceptionHandling,fatfReliability,fraudChecks,ipLevelPrior,ipLevelRequested,ispId,nextReproofDue,proofingType}'),
        ('002-backfill-may-attrs', 'may', 'intentRecord', '{boundPayload,boundTransactionHash,challengeDisplayFormat,derivedIntent,freshnessWindow,response,responseSignature,signingKeyRef}'),
        ('002-backfill-may-attrs', 'may', 'involvedParty', '{iamIPID,iamIPIDData,iamIPSubType,iamIPTags,iamIPType}'),
        ('002-backfill-may-attrs', 'may', 'oauthClientRegistration', '{authorizationDetailsTypes,clientName,clientSecretExpiresAt,clientSecretHash,contacts,dpopBoundAccessTokens,entityId,grantTypes,jwks,jwksUri,organisationId,policyUri,redirectUris,registrationType,requirePushedAuthorizationRequests,responseTypes,scope,sectorIdentifierUri,softwareId,softwareStatement,softwareVersion,tlsClientAuthSubjectDn,trustChain,trustMarks}'),
        ('002-backfill-may-attrs', 'may', 'oauthGrant', '{authenticationEventRef,authorizationDetails,consentRef,entitlementRef,extendedAttributes,grantContext,hashedRefreshTokenValue,resourceAuthorisationRefs,scope,uniqueUserIdentifier,updatedTimestamp}'),
        ('002-backfill-may-attrs', 'may', 'protectedResourceAuthorisation', '{accountIdentifiers,actions,audience,authorizationDetail,constraints,notAfter,notBefore}'),
        ('002-backfill-may-attrs', 'may', 'relatedInvolvedParty', '{relatedInvolvedParty}'),
        ('002-backfill-may-attrs', 'may', 'serviceProfile', '{aal,apiOperation,productRef}'),
        ('002-backfill-may-attrs', 'may', 'serviceRole', '{serviceProfile}'),
        ('002-backfill-may-attrs', 'may', 'serviceUser', '{channel}'),
        ('002-backfill-may-attrs', 'may', 'verifiablePresentationEvidence', '{disclosedClaims,holderBindingMethod,holderBindingResult,issuerAccreditation,nonce,presentationHash,presentationProtocol,statusCheckMethod,statusCheckResult,trustPathRef}'),

        ('003-index-resign-due',       'index', 'entry_resign_due_idx',       NULL),
        ('004-index-next-reproof-due', 'index', 'entry_next_reproof_due_idx', NULL),
        ('005-index-destruction-due',  'index', 'entry_destruction_due_idx',  NULL),

        ('006-add-agent-instance-registry', 'classes',  '{agentInstance,agentDevice,authenticatorBinding,agentLifecycleEvent}', NULL),
        ('006-add-agent-instance-registry', 'may',      'involvedParty', '{pingoneUserId}'),
        ('006-add-agent-instance-registry', 'sequence', 'agent_lifecycle_event_seq', NULL),
        ('006-add-agent-instance-registry', 'index',    'entry_agent_instance_subject_uq',   NULL),
        ('006-add-agent-instance-registry', 'index',    'entry_agent_device_id_uq',          NULL),
        ('006-add-agent-instance-registry', 'index',    'entry_authenticator_binding_id_uq', NULL),
        ('006-add-agent-instance-registry', 'index',    'entry_involved_party_pingone_uq',   NULL),
        ('006-add-agent-instance-registry', 'index',    'entry_agent_event_order_idx',       NULL),
        ('006-add-agent-instance-registry', 'trigger',  'entry_agent_registry_invariants',   NULL),
        ('006-add-agent-instance-registry', 'view',     'v_agent_instance',                  NULL),
        ('006-add-agent-instance-registry', 'vocab',    'agentLifecycleEventCode',           NULL),

        ('007-add-protocol-state', 'classes', '{protocolState}', NULL),
        ('007-add-protocol-state', 'index',   'entry_protocol_state_key_uq',     NULL),
        ('007-add-protocol-state', 'index',   'entry_protocol_state_expiry_idx', NULL),
        ('007-add-protocol-state', 'vocab',   'protocolStateNamespace',          NULL)
      ) AS probe(migration, kind, obj, arg)
      WHERE probe.migration = m.name
    LOOP
      expr := CASE p.kind
        WHEN 'type'     THEN format('to_regtype(%L) IS NOT NULL', 'idm.' || p.obj)
        WHEN 'table'    THEN format('to_regclass(%L) IS NOT NULL', 'idm.' || p.obj)
        WHEN 'view'     THEN format('to_regclass(%L) IS NOT NULL', 'idm.' || p.obj)
        WHEN 'sequence' THEN format('to_regclass(%L) IS NOT NULL', 'idm.' || p.obj)
        -- A CREATE INDEX CONCURRENTLY that failed leaves an INVALID index behind: not the effect.
        WHEN 'index'    THEN format(
          'EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid '
          'JOIN pg_namespace n ON n.oid = c.relnamespace '
          'WHERE n.nspname = ''idm'' AND c.relname = %L AND i.indisvalid)', p.obj)
        WHEN 'trigger'  THEN format(
          'EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = ''idm.entry''::regclass '
          'AND tgname = %L AND NOT tgisinternal)', p.obj)
        WHEN 'classes'  THEN format(
          '(SELECT count(*) FROM idm.object_class WHERE name = ANY (%L::text[])) = cardinality(%L::text[])',
          p.obj, p.obj)
        WHEN 'may'      THEN format(
          'EXISTS (SELECT 1 FROM idm.object_class WHERE name = %L AND may_attrs @> %L::text[])',
          p.obj, p.arg)
        WHEN 'vocab'    THEN format('EXISTS (SELECT 1 FROM idm.vocabulary WHERE vocab = %L)', p.obj)
      END;
      IF expr IS NULL THEN
        RAISE EXCEPTION 'reconcile-ledger: unknown probe kind %', p.kind;
      END IF;

      EXECUTE 'SELECT ' || expr INTO ok;
      total := total + 1;
      IF ok THEN
        passed := passed + 1;
      ELSE
        missing := missing || (p.kind || ' ' || p.obj || coalesce(' ' || p.arg, ''));
      END IF;
    END LOOP;

    IF total = 0 THEN
      RAISE EXCEPTION 'reconcile-ledger: migration % has no probes', m.name;
    END IF;

    recorded := NULL;
    IF ledger THEN
      EXECUTE 'SELECT checksum FROM idm.schema_migration WHERE name = $1' INTO recorded USING m.name;
    END IF;

    status := CASE WHEN passed = total THEN 'present' WHEN passed = 0 THEN 'absent' ELSE 'partial' END;

    IF recorded IS NOT NULL THEN
      IF recorded <> m.checksum THEN
        flagged := flagged || m.name;
        RAISE NOTICE '%  recorded with a DIFFERENT checksum (% in the ledger, % in the file) — drift; left alone',
          rpad(m.name, 34), recorded, m.checksum;
      ELSIF status <> 'present' THEN
        flagged := flagged || m.name;
        RAISE NOTICE '%  recorded, but its effect is % — missing: %',
          rpad(m.name, 34), status, array_to_string(missing, ', ');
        IF m.name = '006-add-agent-instance-registry' AND missing = '{"may involvedParty {pingoneUserId}"}' THEN
          RAISE NOTICE '%  (002 was applied after 006. Re-apply 006 — it is idempotent and restores pingoneUserId.)',
            rpad('', 34);
        END IF;
      ELSE
        RAISE NOTICE '%  recorded', rpad(m.name, 34);
      END IF;
      here := here || m.name;
    ELSIF status = 'present' THEN
      to_record := to_record || m.name;
      record_sums := record_sums || m.checksum;
      here := here || m.name;
      RAISE NOTICE '%  present, unrecorded -> record it', rpad(m.name, 34);
    ELSIF status = 'absent' THEN
      to_apply := to_apply || m.name;
      RAISE NOTICE '%  absent -> apply it', rpad(m.name, 34);
    ELSE
      partials := partials || m.name;
      RAISE NOTICE '%  PARTIAL (%/% probes) — neither record nor apply; missing: %',
        rpad(m.name, 34), passed, total, array_to_string(missing, ', ');
    END IF;
  END LOOP;

  IF mode = 'record' AND cardinality(to_record) > 0 THEN
    -- The same ledger DDL every migration carries.
    CREATE TABLE IF NOT EXISTS idm.schema_migration (
      name        text PRIMARY KEY,
      checksum    text NOT NULL,
      applied_at  timestamptz NOT NULL DEFAULT now(),
      applied_by  text NOT NULL DEFAULT current_user
    );
    INSERT INTO idm.schema_migration (name, checksum, applied_by)
    SELECT v.name, v.checksum, current_user || ' (recorded by reconcile-ledger; effect already present)'
      FROM unnest(to_record, record_sums) AS v(name, checksum)
    ON CONFLICT (name) DO NOTHING;
    RAISE NOTICE 'Recorded % migration(s): %', cardinality(to_record), array_to_string(to_record, ', ');
  ELSIF cardinality(to_record) > 0 THEN
    RAISE NOTICE 'Report only — nothing written. To record %: re-run with PGOPTIONS=''-c ldm.reconcile_mode=record''.',
      array_to_string(to_record, ', ');
  END IF;

  IF cardinality(to_apply) > 0 THEN
    RAISE NOTICE 'To apply, in this order (then run this script again):';
    FOR m IN SELECT unnest(to_apply) AS name LOOP
      RAISE NOTICE '  psql "$DSN" -v ON_ERROR_STOP=1 -f migrations/%.sql', m.name;
      -- 002 sets involvedParty's MAY list outright; 006 adds pingoneUserId by union. If 006 is
      -- already here, applying 002 drops pingoneUserId until 006 runs again.
      IF m.name = '002-backfill-may-attrs' AND '006-add-agent-instance-registry' = ANY (here) THEN
        RAISE NOTICE '  psql "$DSN" -v ON_ERROR_STOP=1 -f migrations/006-add-agent-instance-registry.sql'
                     '   <- re-apply: 002 just dropped pingoneUserId from involvedParty; 006 restores it';
      END IF;
    END LOOP;
  END IF;

  IF cardinality(partials) > 0 THEN
    RAISE NOTICE 'Partial: % — part of the effect is here. Applying could fail or double up, and '
                 'recording would claim what is not there. Reconcile these by hand.',
      array_to_string(partials, ', ');
  END IF;
  IF cardinality(flagged) > 0 THEN
    RAISE NOTICE 'Ledger disagrees with the database or the repo for: %.', array_to_string(flagged, ', ');
  END IF;
  IF cardinality(to_record) = 0 AND cardinality(to_apply) = 0 AND cardinality(partials) = 0
     AND cardinality(flagged) = 0 THEN
    RAISE NOTICE 'Ledger matches the database: nothing to record or apply.';
  END IF;
END
$reconcile$;

COMMIT;
