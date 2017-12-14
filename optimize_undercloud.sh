#!/bin/bash

# this script is not used as long as we have the ability to set these
# in oooq, see https://review.openstack.org/#/c/527718/

yum install -y openstack-utils

openstack-config --set /etc/nova/nova.conf DEFAULT rpc_response_timeout 600
openstack-config --set /etc/nova/nova.conf DEFAULT max_concurrent_builds 2
openstack-config --set /etc/ironic/ironic.conf DEFAULT rpc_response_timeout 600
openstack-service restart nova
openstack-service restart ironic


