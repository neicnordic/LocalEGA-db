#!/usr/bin/env bash
set -Eeo pipefail
# TODO swap to -Eeuo pipefail above (after handling all potentially-unset variables)

# If already initiliazed, then run
[ -s "$PGDATA/PG_VERSION" ] && exec postgres -c config_file=${PGVOLUME:-/ega}/pg.conf

# Default paths
PG_SERVER_CERT=${PG_SERVER_CERT:-/ega/pg.cert}
PG_SERVER_KEY=${PG_SERVER_KEY:-/ega/pg.key}
PG_CA=${PG_CA:-/ega/CA.cert}
PG_VERIFY_PEER=${PG_VERIFY_PEER:-0}

if [ ! -e "${PG_SERVER_CERT}" ] || [ ! -e "${PG_SERVER_KEY}" ]; then
# Generating the SSL certificate + key
openssl req -x509 -newkey rsa:2048 \
    -keyout "${PG_SERVER_KEY}" -nodes \
    -out "${PG_SERVER_CERT}" -sha256 \
    -days 1000 -subj "${SSL_SUBJ}"
fi

if [ ! -d "{$PGDATA}" ]; then
mkdir -p "$PGDATA"
chmod 700 "$PGDATA"
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
pg_ctl -D "$PGDATA" -o "-c listen_addresses='' -c password_encryption=scram-sha-256" -w start

# Create lega database
psql -v ON_ERROR_STOP=1 --username postgres --no-password --dbname postgres <<-'EOSQL'
     SET TIME ZONE 'UTC';
     CREATE DATABASE lega;
EOSQL

# Run sql commands (in order!)
DB_FILES=(/etc/ega/initdb.d/main.sql
	  /etc/ega/initdb.d/download.sql
	  /etc/ega/initdb.d/ebi.sql
	  /etc/ega/initdb.d/grants.sql)

for f in "${DB_FILES[@]}"; do # in order
    echo "$0: running $f";
    echo
    psql -v ON_ERROR_STOP=1 --username postgres --no-password --dbname lega -f "$f";
    echo
done

# Set password for lega_in and lega_out users

[[ -z "${DB_LEGA_IN_PASSWORD}" ]] && echo 'Environment DB_LEGA_IN_PASSWORD is empty' 1>&2 && exit 1
[[ -z "${DB_LEGA_OUT_PASSWORD}" ]] && echo 'Environment DB_LEGA_OUT_PASSWORD is empty' 1>&2 && exit 1

psql -v ON_ERROR_STOP=1 --username postgres --no-password --dbname lega <<EOSQL
     ALTER USER lega_in WITH PASSWORD '${DB_LEGA_IN_PASSWORD}';
     ALTER USER lega_out WITH PASSWORD '${DB_LEGA_OUT_PASSWORD}';
EOSQL

unset DB_LEGA_IN_PASSWORD
unset DB_LEGA_OUT_PASSWORD

# Stop the server
pg_ctl -D "$PGDATA" -m fast -w stop

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
cp /etc/ega/pg.conf ${PGVOLUME:-/ega}/pg.conf

echo
echo 'PostgreSQL setting paths to TLS certificates.'
echo

cat >> ${PGVOLUME:-/ega}/pg.conf <<EOF
ssl_cert_file = '${PG_SERVER_CERT}'
ssl_key_file = '${PG_SERVER_KEY}'
EOF

if [ "${PG_VERIFY_PEER}" == "1" ] && [ -e "${PG_CA}" ]; then
    echo "ssl_ca_file = '${PG_CA}'" >> ${PGVOLUME:-/ega}/pg.conf
fi

echo
echo 'PostgreSQL init process complete; ready for start up.'
echo

exec postgres -c config_file=${PGVOLUME:-/ega}/pg.conf
