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
