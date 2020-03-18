FROM postgres:11.2-alpine

ARG BUILD_DATE
ARG SOURCE_COMMIT

LABEL maintainer "NeIC System Developers"
LABEL org.label-schema.schema-version="1.0"
LABEL org.label-schema.build-date=$BUILD_DATE
LABEL org.label-schema.vcs-url="https://github.com/neicnordic/LocalEGA-db"
LABEL org.label-schema.vcs-ref=$SOURCE_COMMIT

ENV SSL_SUBJ             /C=SE/ST=Sweden/L=Uppsala/O=NBIS/OU=SysDevs/CN=LocalEGA
ENV TZ                   Europe/Stockholm
ENV PGDATA               /ega/data

RUN apk add --no-cache openssl

RUN mkdir -p /etc/ega/initdb.d   && \
    mkdir -p /ega && \
    chown postgres:postgres /ega

COPY pg.conf       /etc/ega/pg.conf
COPY initdb.d      /etc/ega/initdb.d
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 755 /usr/local/bin/entrypoint.sh

VOLUME /ega

USER 70

HEALTHCHECK --interval=3s \
    CMD pg_isready -U lega_out

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
