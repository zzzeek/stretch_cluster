#!/bin/bash

DIRNAME=`dirname $0`
SCRIPT_HOME=`realpath $DIRNAME`
ANSIBLE_HOSTS=${SCRIPT_HOME}/hosts

CHECKOUTS=${SCRIPT_HOME}/checkouts
OVERCLOUD_IMAGES=${SCRIPT_HOME}/downloaded_overcloud_images
INFRARED_CHECKOUT=${CHECKOUTS}/infrared
INFRARED_WORKSPACE=stack


ALL_PLAYBOOK_TAGS="run_galera run_clustercheck setup_pacemaker setup_haproxy setup_keystone_db setup_openstack_services"

: ${CMDS:="cleanup_infrared setup_infrared download_images cleanup_networks build_networks cleanup_vms build_vms run_undercloud run_overcloud build_hosts ${ALL_PLAYBOOK_TAGS}"}


RELEASE=queens
RDO_OVERCLOUD_IMAGES="https://images.rdoproject.org/${RELEASE}/delorean/current-tripleo-rdo/"
IMAGE_URL="file:///${OVERCLOUD_IMAGES}/${RELEASE}/"

set -e
set -x

cleanup_infrared() {
    rm -fr ${INFRARED_CHECKOUT}
}

setup_infrared() {
    SYSTEM_PYTHON_2=/usr/bin/python2

    # sudo yum install git gcc libffi-devel openssl-devel python-virtualenv libselinux-python

    mkdir -p ${CHECKOUTS}

    if [ ! -d ${INFRARED_CHECKOUT} ]; then
        git clone https://github.com/redhat-openstack/infrared.git ${INFRARED_CHECKOUT}
        pushd ${INFRARED_CHECKOUT}
        for patchfile in `ls ${SCRIPT_HOME}/infrared/patches/*.patch`
        do
            patch -p1 < ${patchfile}
        done
        popd
    fi

    cp -uR ${SCRIPT_HOME}/infrared/virsh_topology/* ${INFRARED_CHECKOUT}/plugins/virsh/vars/topology/

    if [[ ! -d ${INFRARED_CHECKOUT}/.venv ]]; then
        pushd ${INFRARED_CHECKOUT}

        ${SYSTEM_PYTHON_2} -m virtualenv .venv
        . .venv/bin/activate
        pip install --upgrade pip
        pip install --upgrade setuptools
        pip install .

        .venv/bin/infrared plugin add all

        popd
    fi
}

download_images() {
    mkdir -p ${OVERCLOUD_IMAGES}/${RELEASE}
    pushd ${OVERCLOUD_IMAGES}/${RELEASE}
    wget --no-parent -r -N ${RDO_OVERCLOUD_IMAGES}
    popd
}

setup_env() {
    . ${INFRARED_CHECKOUT}/.venv/bin/activate

    # checkout -c doesn't work, still errors out if the workspace exists.
    infrared_cmd workspace create ${INFRARED_WORKSPACE} && true
    infrared_cmd workspace checkout ${INFRARED_WORKSPACE}
}

cleanup_networks() {
    set +e

    # NETWORK_NAMES=$( virsh net-list --all | cut -c 1-20 | grep -v "Name" | grep -v "\-\-\-" )
    NETWORK_NAMES="s1external s1provisioning s2external s2provisioning"

    for name in ${NETWORK_NAMES} ; do
        virsh net-destroy $name;
        virsh net-undefine $name;
    done

    set -e

}

cleanup_vms() {
    set +e

    # VM_NAMES=$( virsh list --all | cut -c 5-30 | grep -v "Name" | grep -v "\-\-\-" )

    if [[ $STACK == "stack1" ]]; then
        VM_NAMES="s1undercloud-0 s1controller-0 s1controller-1 s1controller-2 s1compute-0"
    fi

    if [[ $STACK == "stack2" ]]; then
        VM_NAMES="s2undercloud-0 s2controller-0 s2controller-1 s2controller-2 s2compute-0"
    fi

    for name in ${VM_NAMES} ; do
        virsh destroy $name;
        virsh undefine $name;
    done

    set -e

}




build_hosts() {
    # build a hosts file that our own ansible playbook will use, based on the
    # hosts file that oooq builds out when it does full overcloud playbook.
    # includes all the ssh forwarding nicely done

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

[pacemaker_control_nodes]
stack1-overcloud-controller-0
stack2-overcloud-controller-0

EOF
}


infrared_cmd() {
    IR_HOME=${INFRARED_CHECKOUT} ANSIBLE_CONFIG=${INFRARED_CHECKOUT}/ansible.cfg infrared $@
}


run_playbook() {
    pushd ${SCRIPT_HOME}
    ansible-playbook  -vv -i ${ANSIBLE_HOSTS} \
    --tags ${PLAYBOOK_TAGS} playbooks/deploy_stretch_galera.yml
    popd
}

INFRARED_ANSIBLE_ARGS="--host-key $HOME/.ssh/id_rsa  --host-address=127.0.0.2"

build_networks() {
    # use virsh with zero machines so the networks build
    # TODO: propose --networks-only flag for infrared
    infrared_cmd virsh -vv \
        --topology-nodes="s1undercloud:0,s2undercloud:0" \
        --topology-network=stretch_nets \
        ${INFRARED_ANSIBLE_ARGS}
}

build_vms() {
    if [[ $STACK == "stack1" ]]; then
        #NODES="s1undercloud:1,s1controller:3,s1compute:1"
        NODES="s1undercloud:1"
    fi

    if [[ $STACK == "stack2" ]]; then
        #NODES="s2undercloud:1,s2controller:3,s2compute:1"
        NODES="s2undercloud:1"
    fi

    infrared_cmd virsh -vv \
        --topology-nodes="${NODES}" \
        --topology-network=stretch_nets \
        --topology-extend=yes \
        ${INFRARED_ANSIBLE_ARGS}
}

run_undercloud() {
    if [[ $STACK == "stack1" ]]; then
        PROVISIONING_IP_PREFIX=192.168.24
        LIMIT_UNDERCLOUD=s1undercloud-0
    fi

    if [[ $STACK == "stack2" ]]; then
        PROVISIONING_IP_PREFIX=192.168.25
        LIMIT_UNDERCLOUD=s2undercloud-0
    fi

    infrared_cmd tripleo-undercloud -vv --version ${RELEASE} \
        --ansible-args="limit=${LIMIT_UNDERCLOUD},localhost,hypervisor" \
        --config-options DEFAULT.enable_telemetry=false \
        --config-options DEFAULT.local_ip=${PROVISIONING_IP_PREFIX}.1/24 \
        --config-options DEFAULT.network_gateway=${PROVISIONING_IP_PREFIX}.1 \
        --config-options DEFAULT.undercloud_public_vip=${PROVISIONING_IP_PREFIX}.2 \
        --config-options DEFAULT.undercloud_admin_vip=${PROVISIONING_IP_PREFIX}.3 \
        --config-options DEFAULT.network_cidr=${PROVISIONING_IP_PREFIX}.0/24 \
        --config-options DEFAULT.masquerade_network=${PROVISIONING_IP_PREFIX}.0/24 \
        --config-options DEFAULT.dhcp_start=${PROVISIONING_IP_PREFIX}.5 \
        --config-options DEFAULT.dhcp_end=${PROVISIONING_IP_PREFIX}.24 \
        --config-options DEFAULT.inspection_iprange=${PROVISIONING_IP_PREFIX}.100,${PROVISIONING_IP_PREFIX}.120 \
        --config-options DEFAULT.undercloud_nameservers=10.16.36.29,10.11.5.19,10.5.30.160 \
        --images-task import --images-url ${IMAGE_URL} \
        ${INFRARED_ANSIBLE_ARGS}
}


if [[ "${CMDS}" == *"cleanup_infrared"* ]]; then
    cleanup_infrared
fi

if [[ "${CMDS}" == *"setup_infrared"* ]]; then
    setup_infrared
fi

if [[ "${CMDS}" == *"download_images"* ]]; then
    download_images
fi

setup_env

if [[ "${CMDS}" == *"cleanup_networks"* ]]; then
    cleanup_networks
fi

if [[ "${CMDS}" == *"build_networks"* ]]; then
    build_networks
fi

for stack_arg in $STACKS ; do
     STACK="${stack_arg}"

    if [[ "${CMDS}" == *"cleanup_vms"* ]]; then
        cleanup_vms
    fi

    if [[ "${CMDS}" == *"build_vms"* ]]; then
        build_vms
    fi

    if [[ "${CMDS}" == *"run_undercloud"* ]]; then
     run_undercloud
    fi
done


if [[ "${CMDS}" == *"build_hosts"* ]]; then
    build_hosts
fi

PLAYBOOK_TAGS=""

for tag in $ALL_PLAYBOOK_TAGS ; do
    if [[ "${CMDS}" == *"${tag}"* ]]; then
        PLAYBOOK_TAGS="${PLAYBOOK_TAGS}${tag},"
    fi
done

if [ $PLAYBOOK_TAGS ]; then
   run_playbook
fi
