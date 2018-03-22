===============
stretch cluster
===============


Builds two HA/Pacemaker overclouds, then runs an additional Galera cluster that
stretches across both those overclouds, then merges the Keystone databases of
each overcloud to a single Keystone DB on the new Galera, and points both
Keystones at it.

Requirements
============

This demo runs ten VMs simultaneously, so lots of RAM as well as sufficient
disk space (by default on the /home partition).   I run on a server
w/ 188G of physical RAM and 8 CPU cores (more would be better).

General Things
==============

Currently running RDO/Queens Pacemaker / HA (three controller nodes) and we are
also using Docker containers for overcloud services.

The VMs and the undercloud deployment is invoked using Infrared.   Then an
overcloud is deployed from each undercloud using custom Ansible scripts that
are derived from some tripleo-quickstart and some infrared concepts together.
The overcloud nodes use the undercloud as their gateway, and the undercloud
nodes then send packets between the two overclouds using an additional libvirt
network connecting them.

The additional playbook launches a new Galera cluster as well as a new
"clustercheck" service also using Docker containers, re-using the existing
Galera / clustercheck containers as a guide.

Invocation
==========

The whole thing can run from a single script run.   The script should be run
from where it sits, so a hypothetical "do everything" looks like::

    $ git clone https://github.com/zzzeek/stretch_cluster/
    $ cd stretch_cluster
    $ STACKS="stack1 stack2" ./deploy.sh

The STACKS variable refers to two names, "stack1" and "stack2", which refer
to the two overclouds.   Some parts of the script are able to run
against only one stack at a time, if desired.

Breaking down the build further, we can run individual steps::

  # tear down any infrared checkout, build a new infrared checkout, download
  # overcloud qcow images to a local directory
  $ CMDS="cleanup_infrared setup_infrared download_images" ./deploy.sh

  # build out all ten VMs using infrared virsh
  $ CMDS="rebuild_vms" ./deploy.sh

  # deploy underclouds on both stacks, build out a new hosts file that
  # will be used for subsequent ansible roles
  $ STACKS="stack1 stack2" CMDS="deploy_undercloud build_hosts" ./deploy.sh

  # configure and deploy overclouds on both stacks
  $ STACKS="stack1 stack2" CMDS="deploy_overcloud" ./deploy.sh

  # deploy the "stretch galera" setup across the two overclouds
  $ CMDS="deploy_stretch" ./deploy.sh

Not Done Yet
============

* the "deploy stretch" is not working for the infrared version of the script
  at the moment.

* We aren't using Pacemaker to control the new Galera cluster or the clustercheck
  engine, we are just launching the Docker container from Ansible here.

* All the openstack .conf files need to have "region_name" or "os_region_name"
  set correctly, ooo does not seem to do this consistently based on KeystoneRegion
  (some versions did it, others don't) so we have to finish writing out every possible
  region config.   Nova is working so far so you can see "nova --os-region_name region_stack2 list"
  work (assuming you do that from the corresponding region's undercloud)
