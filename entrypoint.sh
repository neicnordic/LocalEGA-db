#!/bin/sh
set -eo pipefail
# TODO swap to -Eeuo pipefail above (after handling all potentially-unset variables)

args=$*

migrate () {

  if echo "$args" | grep -q "nomigrate"; then
      # Allow skipping migrations if they break so one can try to repair the server.
      return
  fi

  runmigration=1;
  migfile="${PGDATA}/migrations.$$"

  echo
  echo "Running schema migrations"
  echo

  PGUSER=$(openssl rand -base64 32 | tr -c -d '[:alpha:]'  | tr '[:upper:]' '[:lower:]')
  PGPASSWORD=$(openssl rand -base64 32 | tr -c -d '[:alnum:]' )

  postgres --single -D "$PGDATA" -c password_encryption=scram-sha-256 <<EOF
CREATE ROLE $PGUSER SUPERUSER LOGIN PASSWORD '$PGPASSWORD';
EOF

  sleep 3
  pg_ctl -D "$PGDATA" -o "-c listen_addresses='' -k \"$PGVOLUME\"" -w start
  sleep 2
  
  export PGUSER
  export PGPASSWORD

  while [ 0 -lt "$runmigration" ]; do

    for f in migratedb.d/*.sql; do
        echo "Running migration script $f"
	psql -h "$PGVOLUME" -v ON_ERROR_STOP=1 --username="$PGUSER" --dbname lega -f "$f";
	echo "Done"
    done 2>&1 | tee "$migfile"
    
    if grep -F 'Doing migration from' "$migfile" ; then
        runmigration=1
	echo
	echo "At least one change occured, running migrations scripts again"
	echo
    else
        runmigration=0
	echo
	echo "No changes registered, done with migrations"
	echo
    fi

    rm -f "$migfile"
  done

  pg_ctl -D "$PGDATA" -w stop
 
  postgres --single -D "$PGDATA" <<EOF
DROP ROLE $PGUSER;
EOF
 
  unset PGPASSWORD
}

PGDATA=${PGVOLUME}/data

# If already initiliazed, then run
if [ -s "$PGDATA/PG_VERSION" ]; then

   # Do a little dance here
   #
   # We want server to run locally only when we run migrations
   # as well as supporting changes that requires database restarts
   # as well as getting output to stdout to support standard
   # container log collections


   migrate

   # Hand over to postgres proper
   exec postgres -c config_file="${PGVOLUME}/pg.conf"
fi

# Default paths
PG_SERVER_CERT=${PG_SERVER_CERT:-${PGVOLUME}/pg.cert}
PG_SERVER_KEY=${PG_SERVER_KEY:-${PGVOLUME}/pg.key}
PG_CA=${PG_CA:-${PGVOLUME}/CA.cert}
PG_VERIFY_PEER=${PG_VERIFY_PEER:-0}

if [ -n "${PKI_VOLUME_PATH}" ]; then
# copying the TLS certificates
    mkdir -p "${PGVOLUME}"/tls
    cp "${PKI_VOLUME_PATH}"/* "${PGVOLUME}"/tls/
    chmod 600 "${PGVOLUME}"/tls/*
fi

if [ ! -e "${PG_SERVER_CERT}" ] || [ ! -e "${PG_SERVER_KEY}" ]; then
# Generating the SSL certificate + key
openssl req -x509 -newkey rsa:2048 \
    -keyout "${PG_SERVER_KEY}" -nodes \
    -out "${PG_SERVER_CERT}" -sha256 \
    -days 1000 -subj "${SSL_SUBJ}"
fi

# Otherwise, do initilization (as postgres user)
initdb --username=postgres # no password: no authentication for postgres user

# Allow "trust" authentication for local connections, during setup
cat > "$PGDATA/pg_hba.conf" <<EOF
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
EOF

# Internal start of the server for setup via 'psql'
# Note: does not listen on external TCP/IP and waits until start finishes
pg_ctl -D "$PGDATA" -o "-c listen_addresses='' -c password_encryption=scram-sha-256 -k $PGVOLUME" -w start

# Create lega database
psql -h "$PGVOLUME" -v ON_ERROR_STOP=1 --username postgres --no-password --dbname postgres <<-'EOSQL'
     SET TIME ZONE 'UTC';
     CREATE DATABASE lega;
EOSQL

for f in docker-entrypoint-initdb.d/*; do
    echo "$0: running $f";
    echo
    psql -h "$PGVOLUME" -v ON_ERROR_STOP=1 --username postgres --no-password --dbname lega -f "$f";
    echo
done

# Set password for lega_in and lega_out users

[ -z "${DB_LEGA_IN_PASSWORD}" ] && echo 'Environment DB_LEGA_IN_PASSWORD is empty' 1>&2 && exit 1
[ -z "${DB_LEGA_OUT_PASSWORD}" ] && echo 'Environment DB_LEGA_OUT_PASSWORD is empty' 1>&2 && exit 1

psql -h "$PGVOLUME" -v ON_ERROR_STOP=1 --username postgres --no-password --dbname lega <<EOSQL
     ALTER USER lega_in WITH PASSWORD '${DB_LEGA_IN_PASSWORD}';
     ALTER USER lega_out WITH PASSWORD '${DB_LEGA_OUT_PASSWORD}';
EOSQL

unset DB_LEGA_IN_PASSWORD
unset DB_LEGA_OUT_PASSWORD

pg_ctl -D "$PGDATA" -w stop

# Run migration scripts
migrate

# Securing the access
#   - Kill 'trust' for local connections
#   - Requiring password authentication for all, in case someone logs onto that machine
#   - Using scram-sha-256 is stronger than md5
#   - Enforcing SSL communication
cat > "$PGDATA/pg_hba.conf" <<EOF
# TYPE   DATABASE   USER      ADDRESS        METHOD
local  	 all  	    all	      		     scram-sha-256
hostssl  all 	    all       127.0.0.1/32   scram-sha-256
hostssl  all  	    all       ::1/128        scram-sha-256
# Note: For the moment, not very network-separated :-p
hostssl  all  	    all       all            scram-sha-256   clientcert=${PG_VERIFY_PEER}
EOF

# Copy config file to presistent volume
cat > "${PGVOLUME}/pg.conf" <<EOF
listen_addresses = '*'
max_connections = 100
authentication_timeout = 10s
password_encryption = scram-sha-256
shared_buffers = 128MB
dynamic_shared_memory_type = posix
log_timezone = 'UTC'
datestyle = 'iso, mdy'
timezone = 'UTC'
# These settings are initialized by initdb, but they can be changed.
lc_messages = 'en_US.utf8'		# locale for system error message strings
lc_monetary = 'en_US.utf8'		# locale for monetary formatting
lc_numeric = 'en_US.utf8'		# locale for number formatting
lc_time = 'en_US.utf8'			# locale for time formatting
# default configuration for text search
default_text_search_config = 'pg_catalog.english'
unix_socket_directories = '${PGVOLUME}'

ssl = on
EOF

echo
echo 'PostgreSQL setting paths to TLS certificates.'
echo

cat >> "${PGVOLUME}/pg.conf" <<EOF
ssl_cert_file = '${PG_SERVER_CERT}'
ssl_key_file = '${PG_SERVER_KEY}'
EOF

if [ "${PG_VERIFY_PEER}" = "1" ] && [ -e "${PG_CA}" ]; then
    echo "ssl_ca_file = '${PG_CA}'" >> "${PGVOLUME}/pg.conf"
fi

echo
echo 'PostgreSQL init process complete; ready for start up.'
echo

exec postgres -c config_file="${PGVOLUME}/pg.conf"
