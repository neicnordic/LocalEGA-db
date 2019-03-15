# LocalEGA database definitions and docker image

We use
[Postgres 11.2](https://github.com/docker-library/postgres/tree/6c3b27f1433ad81675afb386a182098dc867e3e8/11/alpine)
and Alpine 3.9.

The entrypoint creates a self-signed certificate in `/etc/ega/pg.cert`
and the associated private key in `/etc/ega/pg.key`.

Security is hardened:
- We do not use 'trust' even for local connections
- Requiring password authentication for all
- Using scram-sha-256 is stronger than md5
- Enforcing SSL communication

There are 2 users (`lega_in` and `lega_out`), and 2 schemas
(`local_ega` and `local_ega_download`).  A special one is included for
EBI to access the data through `local_ega_ebi`.

The following environment variables can be used to configure the database:

| Variable | Description | Default value |
|---------:|:------------|:--------------|
| PGDATA | The data directory | `/ega/data` |
| DB\_LEGA\_IN\_PASSWORD  | `lega_in`'s password | - |
| DB\_LEGA\_OUT\_PASSWORD  | `lega_out`'s password | - |
| SSL\_SUBJ | Subject for the self-signed certificate creation | `/C=ES/ST=Spain/L=Barcelona/O=CRG/OU=SysDevs/CN=LocalEGA/emailAddress=all.ega@crg.eu` |
| TZ | Timezone for the Postgres server | Europe/Madrid |
