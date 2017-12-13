#!/bin/bash

DIRNAME=`dirname $0`
SCRIPT_HOME=`realpath $DIRNAME`

QUICKSTART_CONFIG=${SCRIPT_HOME}/oooq_config.yml
ANSIBLE_HOSTS=${SCRIPT_HOME}/hosts

CHECKOUTS=${SCRIPT_HOME}/checkouts

QUICKSTART1=${HOME}/.quickstart1
QUICKSTART2=${HOME}/.quickstart2

: ${CMDS:="setup_quickstart cleanup run_undercloud run_overcloud build_hosts"}

if [[ ! $STACKS ]]; then
    echo "STACKS not defined, e.g. STACKS='stack1 stack2'"
    exit -1
fi


RELEASE=master
# RELEASE=pike

set -e
set -x

setup_quickstart() {
    mkdir -p ${CHECKOUTS}
    QUICKSTART_CHECKOUT=${CHECKOUTS}/tripleo-quickstart
    QUICKSTART_EXTRAS_CHECKOUT=${CHECKOUTS}/tripleo-quickstart-extras

    if [ ! -d $QUICKSTART_CHECKOUT ]; then
        git clone https://git.openstack.org/openstack/tripleo-quickstart/ ${QUICKSTART_CHECKOUT}
    fi

    if [ ! -d $QUICKSTART_EXTRAS_CHECKOUT ]; then
        git clone https://git.openstack.org/openstack/tripleo-quickstart-extras/ ${QUICKSTART_EXTRAS_CHECKOUT}
        cd ${QUICKSTART_EXTRAS_CHECKOUT}
        for patchfile in `ls ${SCRIPT_HOME}/oooq-extras-patches/*.patch`
        do
            patch -p1 < ${patchfile}
        done
        cd ${SCRIPT_HOME}

    fi

}

cleanup() {
    rm -fr ${QUICKSTART_ARG}

    set +e
    grep ${STACK} /etc/passwd
    if [ $? != '0' ]; then
        set -e
        return
    fi


    for name in undercloud control_0 control_1 control_2 compute_0 ; do
        sudo -u ${STACK} virsh -c qemu:///session destroy ${name} 
        sudo -u ${STACK} virsh -c qemu:///session undefine ${name} 
    done

    ps -ef | grep -e "^${STACK}" | cut -c 9-16 | xargs -n1 sudo kill -9

    sudo rm -fr /home/${STACK}
    sudo userdel ${STACK}

    set -e

}

setup_env() {

    # establish reqs so that quickstart.sh installs our local
    # quickstart-extras (this should be a lot easier in oooq)
    cat << EOF > ${SCRIPT_HOME}/extras-requirements.txt
file://${QUICKSTART_EXTRAS_CHECKOUT}
EOF

    OOOQ_EXTRA_REQUIREMENTS=${SCRIPT_HOME}/extras-requirements.txt

    CLEANALL="-T all -X"

    UNDERCLOUD_TAGS="--tags untagged,provision,environment,libvirt,undercloud-scripts,undercloud-inventory,overcloud-scripts,undercloud-install,undercloud-post-install,overcloud-prep-config,overcloud-prep-containers,overcloud-prep-images,overcloud-prep-flavors,overcloud-prep-network"

    SKIP_TAGS="--skip-tags overcloud-validate,tripleoui-validate,teardown-all,teardown-environment"
    ALL_TAGS="--tags all"

    OPTS="-n -R ${RELEASE}  --config ${QUICKSTART_CONFIG} --nodes config/nodes/3ctlr_1comp.yml -e undercloud_disk=250  -e   control_memory=8192 -e undercloud_undercloud_nameservers=10.5.30.160 -e enable_pacemaker=true -e enable_port_forward_for_tripleo_ui=false -e tripleo_ui_secure_access=false"

    STACK1_ARGS="-e rh_stack_name=stack1 -e rh_net_range_start=10 -e rh_net_range_end=80 -e ssh_user=stack1 -e non_root_user=stack1 -e  working_dir=/home/stack1 -e undercloud_user=stack1 -w ${QUICKSTART1}"

    STACK2_ARGS="-e rh_stack_name=stack2 -e rh_net_range_start=100 -e rh_net_range_end=170 -e undercloud_external_network_cidr=10.0.1.1/24 -e undercloud_network_cidr=192.168.25.0/24 -e undercloud_external_network_cidr6=2001:db8:fd00:1001::1/64 -e ssh_user=stack2 -e non_root_user=stack2 -e   working_dir=/home/stack2 -e undercloud_user=stack2 -w ${QUICKSTART2}"

    OVERCLOUD_ONLY="--retain-inventory -p quickstart-extras-overcloud.yml --tags overcloud-scripts,overcloud-deploy"
}

install_quickstart() {
    cd ${QUICKSTART_CHECKOUT}
    OOOQ_EXTRA_REQUIREMENTS="${OOOQ_EXTRA_REQUIREMENTS}" ./quickstart.sh ${OPTS} ${UNDERCLOUD_TAGS} ${SKIP_TAGS} ${STACK_ARGS} 127.0.0.2
}

run_undercloud() {
    cd ${QUICKSTART_CHECKOUT}
    OOOQ_EXTRA_REQUIREMENTS="${OOOQ_EXTRA_REQUIREMENTS}" ./quickstart.sh ${OPTS} ${UNDERCLOUD_TAGS} ${SKIP_TAGS} ${STACK_ARGS} 127.0.0.2

}

run_overcloud() {
    cd ${QUICKSTART_CHECKOUT}
    OOOQ_EXTRA_REQUIREMENTS="${OOOQ_EXTRA_REQUIREMENTS}" ./quickstart.sh ${OPTS} ${OVERCLOUD_ONLY} ${SKIP_TAGS} ${STACK_ARGS} 127.0.0.2
}

build_hosts() {
   cat /dev/null > ${ANSIBLE_HOSTS}
   grep ${QUICKSTART1}/hosts -e "^stack1.*ansible" >> ${ANSIBLE_HOSTS}
   grep ${QUICKSTART2}/hosts -e "^stack2.*ansible" >> ${ANSIBLE_HOSTS}

   cat << EOF >> ${ANSIBLE_HOSTS}
[master_overcloud]
stack1-overcloud-controller-0

[follower_overcloud]
stack2-overcloud-controller-0

[stack1]
stack1-overcloud-controller-0
stack1-overcloud-controller-1
stack1-overcloud-controller-2

[stack2]
stack2-overcloud-controller-0
stack2-overcloud-controller-1
stack2-overcloud-controller-2

[galera_nodes]
stack1-overcloud-controller-0
stack2-overcloud-controller-0

EOF
}


if [[ "${CMDS}" == *"setup_quickstart"* ]]; then
    setup_quickstart
fi

setup_env
for stack_arg in $STACKS ; do
     STACK="${stack_arg}"
     if [[ $stack_arg == "stack1" ]]; then
        STACK_ARGS="${STACK1_ARGS}"
        QUICKSTART_ARG="${QUICKSTART1}"
     elif [[ $stack_arg == "stack2" ]]; then
        STACK_ARGS="${STACK2_ARGS}"
        QUICKSTART_ARG="${QUICKSTART2}"
     else
        echo "no such stack ${stack_arg}"
        exit -1
     fi


     if [[ "${CMDS}" == *"cleanup"* ]]; then
         cleanup
     fi

     if [[ "${CMDS}" == *"run_undercloud"* ]]; then
         run_undercloud
     fi

     if [[ "${CMDS}" == *"run_overcloud"* ]]; then
         run_overcloud 
     fi

done

if [[ "${CMDS}" == *"build_hosts"* ]]; then
    build_hosts
fi



