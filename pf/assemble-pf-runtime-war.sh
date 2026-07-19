#!/usr/bin/env bash
# Assemble pf-runtime.war = STOCK PingFederate runtime war + the OIDF module jar + jose4j, injected
# into WEB-INF/lib, PLUS a small web.xml edit to register the SSF logout filter.
#
# Annotation-mapped module classes (@WebServlet servlets like RegisteredClientsServlet, the SSF servlets)
# auto-map once the jar is on WEB-INF/lib (pf-runtime.war scans it). Plain filters that must run over PF's
# OWN endpoints are NOT annotated (mapping them by annotation would only bind the module's context), so they
# are registered explicitly in this war's WEB-INF/web.xml:
#   - SsfLogoutSignal (LogoutEventFilter) over /idp/init_logout.openid → emits caep.session-revoked SETs.
# (The OidfAutoRegistration filter over /as/token.oauth2 is the same shape — add it here the same way when
#  you want token-time auto-registration wired; left out so this change only turns on the logout signal.)
#
# Inputs (all provided by the CI job — see .github/workflows/deploy-pingfederate.yml):
#   $1  STOCK_WAR   path to the stock pf-runtime.war extracted from the pingidentity/pingfederate image
#   $2  MODULE_JAR  path to the built module jar (pf-integration → target/oidf.jar)
#   $3  JOSE4J_JAR  path to jose4j jar, or "-" to skip. SKIP for pf-runtime.war merging: PF already
#                   ships jose4j on its server classpath, and bundling a second copy in WEB-INF/lib
#                   causes a LinkageError (loader constraint violation) when PF-loaded jose4j types
#                   (JwksEndpointKeyAccessor results) cross into module code.
#   $4  OUT_WAR     path to write the assembled pf-runtime.war
set -euo pipefail
STOCK_WAR="$1"; MODULE_JAR="$2"; JOSE4J_JAR="$3"; OUT_WAR="$4"
MODULE_NAME="pf-oidf-modules-0.0.1-SNAPSHOT.jar"   # keep the WEB-INF/lib entry name stable

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cp "$STOCK_WAR" "$OUT_WAR"
# Resolve OUT_WAR to an absolute path — the `zip` calls below run from inside $work, so a relative
# OUT_WAR would land in the temp dir instead of the intended output.
OUT_WAR="$(cd "$(dirname "$OUT_WAR")" && pwd)/$(basename "$OUT_WAR")"
mkdir -p "$work/WEB-INF/lib"
cp "$MODULE_JAR" "$work/WEB-INF/lib/$MODULE_NAME"
if [[ "$JOSE4J_JAR" != "-" ]]; then
  cp "$JOSE4J_JAR" "$work/WEB-INF/lib/$(basename "$JOSE4J_JAR")"
  ( cd "$work" && zip -q "$OUT_WAR" WEB-INF/lib/"$MODULE_NAME" WEB-INF/lib/"$(basename "$JOSE4J_JAR")" )
else
  ( cd "$work" && zip -q "$OUT_WAR" WEB-INF/lib/"$MODULE_NAME" )
fi

# --- web.xml surgery: register the SSF logout filter (idempotent) ---
unzip -oq "$OUT_WAR" WEB-INF/web.xml -d "$work"
WEBXML="$work/WEB-INF/web.xml"
if [[ ! -f "$WEBXML" ]]; then
  echo "ERROR: stock pf-runtime.war has no WEB-INF/web.xml" >&2; exit 1
fi
if grep -q "SsfLogoutSignal" "$WEBXML"; then
  echo "web.xml: SsfLogoutSignal already registered — leaving as is"
else
  grep -q "</web-app>" "$WEBXML" || { echo "ERROR: web.xml has no </web-app> to insert before" >&2; exit 1; }
  awk '
    /<\/web-app>/ && !done {
      print "  <filter>"
      print "    <filter-name>SsfLogoutSignal</filter-name>"
      print "    <filter-class>com.pingidentity.ps.oidf.servlet.ssf.LogoutEventFilter</filter-class>"
      print "  </filter>"
      print "  <filter-mapping>"
      print "    <filter-name>SsfLogoutSignal</filter-name>"
      print "    <url-pattern>/idp/init_logout.openid</url-pattern>"
      print "  </filter-mapping>"
      done=1
    }
    { print }
  ' "$WEBXML" > "$WEBXML.new" && mv "$WEBXML.new" "$WEBXML"
  ( cd "$work" && zip -q "$OUT_WAR" WEB-INF/web.xml )
  echo "web.xml: registered SsfLogoutSignal over /idp/init_logout.openid"
fi

echo "assembled $OUT_WAR:"
unzip -l "$OUT_WAR" | grep -E "pf-oidf-modules" || { echo "ERROR: module jar not present in war"; exit 1; }
unzip -p "$OUT_WAR" WEB-INF/web.xml | grep -q "SsfLogoutSignal" \
  || { echo "ERROR: SsfLogoutSignal filter mapping not present in assembled war" >&2; exit 1; }
echo "verified: SsfLogoutSignal filter mapped in $OUT_WAR"
