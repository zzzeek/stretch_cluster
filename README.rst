===============
stretch cluster
===============


Builds two HA/Pacemaker overclouds, then runs an additional Galera cluster that
stretches across both those overclouds, then merges the Keystone databases of
each overcloud to a single Keystone DB on the new Galera, and points both
Keystones at it.

Requirements
============

This demo runs ten VMs simultaneously, so lots of RAM.   I run on a server
w/ 188G of physical RAM and 8 CPU cores (more would be better).

General Things
==============

We running OSP12 using Pacemaker / HA (three controller nodes) and we are
also using Docker containers for overcloud services.

We run tripleo quickstart to generate two separate undercloud and overcloud
environments, however these both share the *same* libvirt network devices on
the hypervisor host.  In particular, the "external" libvirt network that
tripleo quickstart creates is where both overclouds run their networks. For
simplicity in this demo, both overclouds use the same CIDRs for each of their
networks so that all overcloud networks are shared between both clouds, though
in practice only one network would need to be shared between datacenters for
the Galera cluster to operate upon.  See oooq_config.yml for defails on how the
networks are configured.

The additional playbook launches a new Galera cluster as well as a new
"clustercheck" service also using Docker containers, re-using the existing
Galera / clustercheck containers as a guide.

Invocation
==========

The whole thing can run from a single script run, however in practice, the
tripleo-quickstart steps *frequently* fail and need to be re-run, so running
each step piecemeal is more practical.    The script has a slightly quirky
interface due to the fact that quickstart runs fail so often, and once you
get one to work you *really* won't want to lose it by accident.

The script should be run from where it sits, so a hypothetical "do everything"
looks like::

    $ git clone https://github.com/zzzeek/stretch_cluster/
    $ cd stretch_cluster
    $ STACKS="stack1 stack2" ./deploy_overclouds.sh

The STACKS variable refers to two names, "stack1" and "stack2", which are
the names given to the two Tripleo / quickstart setups.   Those are the
names, they're hardcoded at the moment.   When running the parts of the
script that build up the quickstart stacks, you always need to specify
explicitly the stacks you want it to actually work with.  This is because
it tears them down completely and starts all over again by default, and
if you've tried four times to get a quickstart build to complete due to
various RDO servers being slow / down, you will be *very* upset to lose one.

In practice, one would likely want to build things partially.   What the
script does is determined by setting the STACKS and CMDS variables.   So
a complete run one step at a time looks like::

    # get oooq installed and set up, clean up VMs that might have been around.
    # this part runs without issue.
    $ STACKS="stack1 stack2" CMDS="setup_quickstart cleanup" ./deploy_overclouds.sh

    # build underclouds w oooq.  This part works about 90% of the time
    $ STACKS="stack1" CMDS="run_undercloud" ./deploy_overclouds.sh
    $ STACKS="stack2" CMDS="run_undercloud" ./deploy_overclouds.sh

    # build overclouds w oooq.  This part works about 60% of the time :(
    $ STACKS="stack1" CMDS="run_overcloud" ./deploy_overclouds.sh
    $ STACKS="stack2" CMDS="run_overcloud" ./deploy_overclouds.sh

    # run the stretch playbook.   Does not run per-stack so we don't need
    # STACKS.  Works every time :)
    # this will set up galera, clustercheck, haproxy endpoints, VIPs under
    # pacemaker, copy and merge keystone databases to the new cluster and
    # re-point services.
    $ CMDS="hosts run_galera run_clustercheck setup_pacemaker \
      setup_haproxy setup_keystone_db setup_openstack_services" ./deploy_overclouds.sh

When the undercloud build fails on "preparing for containerized deployment", which is 
frequent because it needs to download dozens of docker images::

    UNDERCLOUD_TAGS="--tags undercloud-post-install,overcloud-prep-containers" STACKS="stack1" CMDS=run_undercloud ./deploy_overclouds.sh

Not Done Yet
============

* We aren't using Pacemaker to control the new Galera cluster or the clustercheck
  engine, we are just launching the Docker container from Ansible here.

* All the openstack .conf files need to have "region_name" or "os_region_name"
  set correctly, ooo does not seem to do this consistently based on KeystoneRegion
  (some versions did it, others don't) so we have to finish writing out every possible
  region config.   Nova is working so far so you can see "nova --os-region_name region_stack2 list" 
  work (assuming you do that from the corresponding region's undercloud)
