FROM postgres:11.2-alpine
LABEL maintainer "EGA System Developers"

ENV SSL_SUBJ             /C=ES/ST=Spain/L=Barcelona/O=CRG/OU=SysDevs/CN=LocalEGA/emailAddress=all.ega@crg.eu
ENV TZ                   Europe/Madrid
ENV PGDATA               /ega/data

EXPOSE 5432
VOLUME /ega/data

RUN apk add --no-cache openssl

RUN mkdir -p /etc/ega/initdb.d            && \
    chown -R postgres /etc/ega            && \
    mkdir -p /var/run/postgresql          && \
    chown -R postgres /var/run/postgresql && \
    chmod 2777 /var/run/postgresql

COPY pg.conf       /etc/ega/pg.conf
COPY initdb.d      /etc/ega/initdb.d
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
