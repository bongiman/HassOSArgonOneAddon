ARG BUILD_FROM
# hadolint ignore=DL3006
FROM $BUILD_FROM

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV LANG C.UTF-8
WORKDIR /data

RUN apk update && apk add --no-cache i2c-tools bc

COPY run.sh /
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
