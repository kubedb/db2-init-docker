FROM alpine

LABEL org.opencontainers.image.source = https://github.com/kubedb/db2-init-docker
ARG TARGETOS
ARG TARGETARCH

RUN apk add --no-cache bash

RUN set -x \
	&& apk add --update ca-certificates curl


RUN mkdir /init-script

COPY scripts /tmp/scripts
COPY init-script /init-script

RUN curl -fsSL -o /tmp/scripts/tini https://github.com/kubedb/tini/releases/download/v0.20.0/tini-static-${TARGETARCH} \
    && chmod +x /tmp/scripts/tini

# COPY --from=0 /tini /tmp/scripts/tini/

RUN chmod +x /tmp/scripts/*.sh
RUN chmod +x /init-script/*.sh

ENTRYPOINT ["/init-script/run.sh"]