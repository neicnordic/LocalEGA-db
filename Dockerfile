FROM postgres:11.2-alpine

ARG BUILD_DATE
ARG SOURCE_COMMIT

LABEL maintainer "EGA System Developers"
LABEL org.label-schema.schema-version="1.0"
LABEL org.label-schema.build-date=$BUILD_DATE
LABEL org.label-schema.vcs-url="https://github.com/EGA-archive/LocalEGA-db"
LABEL org.label-schema.vcs-ref=$SOURCE_COMMIT

ENV SSL_SUBJ             /C=ES/ST=Spain/L=Barcelona/O=CRG/OU=SysDevs/CN=LocalEGA/emailAddress=dev.ega@crg.eu
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
