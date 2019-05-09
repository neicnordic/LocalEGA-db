#!/usr/bin/env bash
set -Eeo pipefail
# TODO swap to -Eeuo pipefail above (after handling all potentially-unset variables)

# Default paths
PG_CERTFILE=${PG_CERTFILE:-/etc/ega/pg.cert}
PG_KEYFILE=${PG_KEYFILE:-/etc/ega/pg.key}
PG_CACERTFILE=${PG_CACERTFILE:-/etc/ega/CA.cert}
PG_VERIFY_PEER=${PG_VERIFY_PEER:-0}

if [ "$(id -u)" = '0' ]; then
    # When root
    mkdir -p "$PGDATA"
    chown -R postgres "$PGDATA"
    chmod 700 "$PGDATA"

    if [ ! -e "${PG_CERTFILE}" ] || [ ! -e "${PG_KEYFILE}" ]; then
	# Generating the SSL certificate + key
	openssl req -x509 -newkey rsa:2048 \
		-keyout "${PG_KEYFILE}" -nodes \
		-out "${PG_CERTFILE}" -sha256 \
		-days 1000 -subj ${SSL_SUBJ}
    else
	# Otherwise use the injected ones.
	echo "Using the injected certificate/privatekey pair" 
    fi
    # Fixing the ownership and permissions
    chown postgres:postgres "${PG_KEYFILE}" "${PG_CERTFILE}"
    chmod 600 "${PG_KEYFILE}"

    chown postgres:postgres /etc/ega/pg.conf
    
    # Run again as 'postgres'
    exec su-exec postgres "$BASH_SOURCE" "$@"
fi

# If already initiliazed, then run
[ -s "$PGDATA/PG_VERSION" ] && exec postgres -c config_file=/etc/ega/pg.conf

# Otherwise, do initilization (as postgres user)
initdb --username=postgres # no password: no authentication for postgres user

# Allow "trust" authentication for local connections, during setup
cat > $PGDATA/pg_hba.conf <<EOF
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

for f in ${DB_FILES[@]}; do # in order
    echo "$0: running $f";
    echo
    psql -v ON_ERROR_STOP=1 --username postgres --no-password --dbname lega -f $f;
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
cat > $PGDATA/pg_hba.conf <<EOF
# TYPE   DATABASE   USER      ADDRESS        METHOD
local  	 all  	    all	      		     scram-sha-256
hostssl  all 	    all       127.0.0.1/32   scram-sha-256
hostssl  all  	    all       ::1/128        scram-sha-256
# Note: For the moment, not very network-separated :-p
hostssl  all  	    all       all            scram-sha-256   clientcert=${PG_VERIFY_PEER}
EOF


echo
echo 'PostgreSQL setting paths to TLS certificates.'
echo

cat >> /etc/ega/pg.conf <<EOF
ssl_cert_file = '${PG_CERTFILE}'
ssl_key_file = '${PG_KEYFILE}'
EOF

if [ "${PG_VERIFY_PEER}" == "1" ] && [ -e "${PG_CACERTFILE}" ]; then
    echo "ssl_ca_file = '${PG_CACERTFILE}'" >> /etc/ega/pg.conf
fi

echo
echo 'PostgreSQL init process complete; ready for start up.'
echo

exec postgres -c config_file=/etc/ega/pg.conf
