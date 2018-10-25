===============
stretch cluster
===============

Builds two HA/Pacemaker overclouds with a Galera cluster streched between
them which is then used by Keystone for shared identity service.

Originally, this process involved building the two overclouds separately
then configuring a new Galera cluster on top of them.  It has evolved so
that first the additional Galera cluster would be part of tripleo, but
still using a separate "merge" step, and now finally to tripleo is patched
to completely deploy two overclouds, where the second one builds right on
top of the existing stretched Galera cluster.

Blueprint for the feature being developed at:

https://review.openstack.org/#/c/600555/

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

The two overclouds are deployed with Keystone interacting with a separate
Galera database called the "stretch", or "global" database that is shared
as one Galera cluster over both overclouds.


The demo patches tripleo-heat-templates, puppet-
tripleo with the ability to deploy an addtional Galera cluster.  It
also patches the galera docker image and the controller image
a modified version of the Galera resource agent.

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
  # will be used for subsequent ansible roles, set up routing between
  # the two overclouds
  $ STACKS="stack1 stack2" CMDS="build_hosts deploy_undercloud setup_routes" ./deploy.sh

  # configure and deploy overclouds on both stacks
  $ STACKS="stack1 stack2" CMDS="deploy_overcloud" ./deploy.sh


