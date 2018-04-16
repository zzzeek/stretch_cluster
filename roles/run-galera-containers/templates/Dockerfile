FROM {{ galera_image }}

USER root

COPY galera_ra.sh  /usr/lib/ocf/resource.d/heartbeat/galera
COPY setup_stretch_database.sh /setup_stretch_database.sh


RUN \
    yum install -y openssh-clients && \
	chmod 755 /usr/lib/ocf/resource.d/heartbeat/galera && \
	chmod 755 /setup_stretch_database.sh

