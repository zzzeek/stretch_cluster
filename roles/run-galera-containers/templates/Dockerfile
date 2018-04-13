FROM {{ galera_image }}

USER root

RUN \
    yum install -y openssh-clients

COPY galera_ra.sh  /usr/lib/ocf/resource.d/heartbeat/galera


