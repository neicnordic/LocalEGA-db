# LocalEGA database definitions and docker image

We use
[Postgres 11.2](https://github.com/docker-library/postgres/tree/6c3b27f1433ad81675afb386a182098dc867e3e8/11/alpine)
and Alpine 3.9.

Security is hardened:
- We do not use 'trust' even for local connections
- Requiring password authentication for all
- Using scram-sha-256 is stronger than md5
- Enforcing TLS communication
- Enforcing client-certificate verification

## Configuration

There are 2 users (`lega_in` and `lega_out`), and 2 schemas
(`local_ega` and `local_ega_download`).  A special one is included for
EBI to access the data through `local_ega_ebi`.

The following environment variables can be used to configure the database:

| Variable                | Description                       | Default value       |
|------------------------:|:----------------------------------|:--------------------|
| PGVOLUME                | Mountpoint for the writble volume | /var/lib/postgresql |
| DB\_LEGA\_IN\_PASSWORD  | `lega_in`'s password              | -                   |
| DB\_LEGA\_OUT\_PASSWORD | `lega_out`'s password             | -                   |
| TZ                      | Timezone for the Postgres server  | Europe/stockholm    |

## TLS support

| Variable         | Description                                      | Default value       |
|-----------------:|:-------------------------------------------------|:--------------------|
| PG\_SERVER\_CERT | Public Certificate in PEM format                 | `$PGVOLUME/pg.cert` |
| PG\_SERVER\_KEY  | Private Key in PEM format                        | `$PGVOLUME/pg.key`  |
| PG\_CA           | Public CA Certificate in PEM format              | `$PGVOLUME/CA.cert` |
| PG\_VERIFY\_PEER | Enforce client verification                      | 0                   |
| SSL\_SUBJ        | Subject for the self-signed certificate creation | `/C=SE/ST=Sweden/L=Uppsala/O=NBIS/OU=SysDevs/CN=LocalEGA` |

If not already injected, the files located at `PG_SERVER_CERT` and `PG_SERVER_KEY` will be generated, as a self-signed public/private certificate pair, using `SSL_SUBJ`.

Client verification is enforced if and only if `PG_CA` exists and `PG_VERIFY_PEER` is set to `1`.

