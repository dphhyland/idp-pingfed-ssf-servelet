# Demo PingFederate: stock 13.0.3 + the pf-oidf-modules SSF transmitter merged into pf-runtime.war
# (root context, logout filter registered), Postgres JDBC driver for the LDM store, DevOps licensing.
# No data.zip — OAuth config (ATM, mapping, scope, receiver client) is bootstrapped via the admin API
# by scripts/bootstrap-pf.sh after boot.
FROM pingidentity/pingfederate:13.0.3-alpine_3.23.4-al21-latest
USER root

COPY assemble-pf-runtime-war.sh /tmp/assemble-pf-runtime-war.sh
COPY pf-oidf-modules.jar /tmp/pf-oidf-modules.jar

# Postgres JDBC driver (for LdmSsfStore's direct-JDBC demo path)
ADD https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.3/postgresql-42.7.3.jar /tmp/postgresql.jar

RUN mkdir -p /opt/in/instance/server/default/deploy \
 && apk add --no-cache zip unzip bash \
 && STOCK="$(find /opt -name pf-runtime.war 2>/dev/null | grep -v '/opt/in/' | head -1)" \
 && { [ -n "$STOCK" ] || { echo 'stock pf-runtime.war not found'; exit 1; }; } \
 && bash /tmp/assemble-pf-runtime-war.sh "$STOCK" /tmp/pf-oidf-modules.jar - \
      /opt/in/instance/server/default/deploy/pf-runtime.war \
 && mkdir -p /tmp/w/WEB-INF/lib && cp /tmp/postgresql.jar /tmp/w/WEB-INF/lib/postgresql-42.7.3.jar \
 && ( cd /tmp/w && zip -q /opt/in/instance/server/default/deploy/pf-runtime.war WEB-INF/lib/postgresql-42.7.3.jar ) \
 && chown 9031:0 /opt/in/instance/server/default/deploy/pf-runtime.war \
 && rm -rf /tmp/assemble-pf-runtime-war.sh /tmp/pf-oidf-modules.jar /tmp/postgresql.jar /tmp/w

# Plain-HTTP runtime listener on 9080 (in-container introspection calls avoid the self-signed cert)
RUN sed -i 's/^pf.http.port=-1/pf.http.port=9080/' /opt/staging/instance/bin/run.properties.subst.default

USER 9031:0
