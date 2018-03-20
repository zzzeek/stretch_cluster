#!/bin/bash

DIRNAME=`dirname $0`
SCRIPT_HOME=`realpath $DIRNAME`


NAMESERVERS="10.16.36.29,10.11.5.19,10.5.30.160"
CHECKOUTS=${SCRIPT_HOME}/checkouts
OVERCLOUD_IMAGES=${SCRIPT_HOME}/downloaded_overcloud_images
INFRARED_CHECKOUT=${CHECKOUTS}/infrared
INFRARED_WORKSPACE_NAME=stack
INFRARED_WORKSPACE=${INFRARED_CHECKOUT}/.workspaces/${INFRARED_WORKSPACE_NAME}
ANSIBLE_PLAYBOOK=${INFRARED_CHECKOUT}/.venv/bin/ansible-playbook

COMBINED_HOSTS=${SCRIPT_HOME}/hosts

SETUP_CMDS="cleanup_infrared setup_infrared download_images"
BUILD_ENVIRONMENT_CMDS="rebuild_vms deploy_undercloud build_hosts"
DEPLOY_STRETCH_TAGS="run_galera run_clustercheck setup_pacemaker setup_haproxy setup_keystone_db setup_openstack_services"

DEPLOY_OVERCLOUD_TAGS="setup_vlan create_instackenv introspect_nodes create_flavors build_heat_config prepare_container_images deploy_overcloud"


: ${CMDS:="${SETUP_CMDS} ${BUILD_ENVIRONMENT_CMDS} ${DEPLOY_OVERCLOUD_TAGS} ${DEPLOY_STRETCH_TAGS}"}


RELEASE=queens
RDO_OVERCLOUD_IMAGES="https://images.rdoproject.org/${RELEASE}/delorean/current-tripleo-rdo/"
IMAGE_URL="file:///tmp/"

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
    curl -O ${RDO_OVERCLOUD_IMAGES}/ironic-python-agent.tar
    curl -O ${RDO_OVERCLOUD_IMAGES}/overcloud-full.tar
    popd
}

reset_workspace() {
    rm -fr ${INFRARED_WORKSPACE}
}

setup_infrared_env() {
    if [[ -d $INFRARED_CHECKOUT ]] ; then
        . ${INFRARED_CHECKOUT}/.venv/bin/activate

        # checkout -c doesn't work, still errors out if the workspace exists.
        infrared_cmd workspace create ${INFRARED_WORKSPACE_NAME} && true
        infrared_cmd workspace checkout ${INFRARED_WORKSPACE_NAME}
    fi
}

cleanup_networks() {
    set +e

    NETWORK_NAMES=$( sudo virsh net-list --all | cut -c 1-20 | grep -e '^ *\(s1\|s2\|stretch\)' )

    for name in ${NETWORK_NAMES} ; do
        sudo virsh net-destroy $name;
        sudo virsh net-undefine $name;
    done

    set -e

}

cleanup_vms() {
    set +e

    VM_NAMES=""

    if [[ "${STACKS}" == *"stack1"* ]]; then
        NAMES=$( sudo virsh list --all | cut -c 5-30 | grep -e "^\ *s1" )
        VM_NAMES="${VM_NAMES} ${NAMES}"
    fi

    if [[ "${STACKS}" == *"stack2"* ]]; then
        NAMES=$( sudo virsh list --all | cut -c 5-30 | grep -e "^\ *s2" )
        VM_NAMES="${VM_NAMES} ${NAMES}"
    fi

    for name in ${VM_NAMES} ; do
        sudo virsh destroy $name;
        sudo virsh undefine $name;
    done

    set -e

}


infrared_cmd() {
    IR_HOME=${INFRARED_CHECKOUT} ANSIBLE_CONFIG=${INFRARED_CHECKOUT}/ansible.cfg infrared $@
}


build_networks() {
    # use virsh with zero machines so the networks build
    # TODO: propose --networks-only flag for infrared
    infrared_cmd virsh -vv \
        --topology-nodes="s1undercloud:0,s2undercloud:0" \
        --topology-network=stretch_nets \
        --ansible-args="skip-tags=vms" \
        --host-key $HOME/.ssh/id_rsa  --host-address=127.0.0.2
}

build_vms() {

    NODES=""

    if [[ "${STACKS}" == *"stack1"* ]]; then
        #NODES="s1undercloud:1,s1controller:3,s1compute:1,"
        NODES="${NODES}s1undercloud:1,"
    fi

    if [[ "${STACKS}" == *"stack2"* ]]; then
        #NODES="s2undercloud:1,s2controller:3,s2compute:1,"
        NODES="${NODES}s2undercloud:1,"
    fi

    # trim trailing comma
    NODES=${NODES:0:-1}

    infrared_cmd virsh -vv \
        --topology-nodes="${NODES}" \
        --topology-network=stretch_nets \
        --topology-extend=yes \
        --host-key $HOME/.ssh/id_rsa  --host-address=127.0.0.2


}

build_hosts() {
    # build out hostfiles for next steps.   different steps need a different
    # view of hosts.

    # build stack1-only hosts file
    cat ${INFRARED_WORKSPACE}/hosts-prov  | grep -e "^\[\\|s1\|localhost\|hypervisor" > ${INFRARED_WORKSPACE}/stack1_hosts_install

    # build stack2-only hosts file
    cat ${INFRARED_WORKSPACE}/hosts-prov  | grep -e "^\[\\|s2\|localhost\|hypervisor" > ${INFRARED_WORKSPACE}/stack2_hosts_install

   cat /dev/null > ${COMBINED_HOSTS}
   grep ${INFRARED_WORKSPACE}/hosts -e ".*ansible" >> ${COMBINED_HOSTS}

   cat << EOF >> ${COMBINED_HOSTS}

[undercloud]
s1undercloud-0
s2undercloud-0

[master_overcloud]
s1controller-0

[follower_overcloud]
s2controller-0

[stack1]
s1controller-0
s1controller-1
s1controller-2

[stack2]
s2-controller-0
s2-controller-1
s2-controller-2

[galera_nodes]
s1-controller-0
s2-controller-0

[pacemaker_control_nodes]
s1-controller-0
s2-controller-0

EOF
}

upload_images() {
    pushd ${INFRARED_CHECKOUT}
    if [[ "${STACKS}" == *"stack1"* ]]; then
        scp -F ${INFRARED_WORKSPACE}/ansible.ssh.config ${OVERCLOUD_IMAGES}/${RELEASE}/* s1undercloud-0:/tmp/
    fi
    if [[ "${STACKS}" == *"stack2"* ]]; then
        scp -F ${INFRARED_WORKSPACE}/ansible.ssh.config ${OVERCLOUD_IMAGES}/${RELEASE}/* s2undercloud-0:/tmp/
    fi
    popd
}

deploy_undercloud() {

    if [[ $STACK == "stack1" ]]; then
        PROVISIONING_IP_PREFIX=192.168.24
        LIMIT_HOSTFILE=${INFRARED_WORKSPACE}/stack1_hosts_install
        WRITE_HOSTFILE=${INFRARED_WORKSPACE}/stack1_hosts_undercloud
    fi

    if [[ $STACK == "stack2" ]]; then
        PROVISIONING_IP_PREFIX=192.168.25
        LIMIT_HOSTFILE=${INFRARED_WORKSPACE}/stack2_hosts_install
        WRITE_HOSTFILE=${INFRARED_WORKSPACE}/stack2_hosts_undercloud
    fi

    infrared_cmd tripleo-undercloud -vv --version ${RELEASE} \
        --inventory=${LIMIT_HOSTFILE} \
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
        --config-options DEFAULT.undercloud_nameservers="${NAMESERVERS}" \
        --images-task import --images-url ${IMAGE_URL}

    cp ${INFRARED_WORKSPACE}/hosts ${WRITE_HOSTFILE}
}

deploy_overcloud() {
    if [[ $STACK == "stack1" ]]; then
        PROVISIONING_IP_PREFIX=192.168.24
        UNDERCLOUD_EXTERNAL_NETWORK_CIDR=10.0.0.1/24
        ANSIBLE_HOSTS=${INFRARED_WORKSPACE}/stack1_hosts_undercloud
    fi

    if [[ $STACK == "stack2" ]]; then
        PROVISIONING_IP_PREFIX=192.168.25
        UNDERCLOUD_EXTERNAL_NETWORK_CIDR=10.0.1.1/24
        ANSIBLE_HOSTS=${INFRARED_WORKSPACE}/stack2_hosts_undercloud
    fi

    PLAYBOOK_TAGS=""

    for tag in $DEPLOY_OVERCLOUD_TAGS ; do
        if [[ "${CMDS}" == *"${tag}"* ]]; then
            PLAYBOOK_TAGS="${PLAYBOOK_TAGS}${tag},"
        fi
    done

    if [ $PLAYBOOK_TAGS ]; then

        pushd ${SCRIPT_HOME}
        ${ANSIBLE_PLAYBOOK} -vv \
            -i ${ANSIBLE_HOSTS} \
            -e release_name=${RELEASE} \
            -e undercloud_external_network_cidr=${UNDERCLOUD_EXTERNAL_NETWORK_CIDR} \
            -e working_dir=/home/stack \
            playbooks/deploy_overcloud.yml
        popd

fi
}

deploy_stretch_cluster() {
    PLAYBOOK_TAGS=""

    for tag in $DEPLOY_STRETCH_TAGS ; do
        if [[ "${CMDS}" == *"${tag}"* ]]; then
            PLAYBOOK_TAGS="${PLAYBOOK_TAGS}${tag},"
        fi
    done

    if [ $PLAYBOOK_TAGS ]; then
        pushd ${SCRIPT_HOME}
        ${ANSIBLE_PLAYBOOK} -vv \
            -i ${COMBINED_HOSTS} \
            --tags ${PLAYBOOK_TAGS} playbooks/deploy_stretch_galera.yml
        popd
    fi


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

if [[ "${CMDS}" == *"rebuild_vms"* ]]; then
    reset_workspace
fi

setup_infrared_env

if [[ "${CMDS}" == *"rebuild_vms"* || "${CMDS}" == *"cleanup_virt"* ]]; then
    cleanup_networks
    cleanup_vms
fi

if [[ "${CMDS}" == *"rebuild_vms"* ]]; then
    build_networks
    build_vms
    build_hosts
    upload_images
fi


for stack_arg in $STACKS ; do
    STACK="${stack_arg}"

    if [[ "${CMDS}" == *"deploy_undercloud"* ]]; then
     deploy_undercloud
     build_hosts
    fi

    if [[ "${CMDS}" == *"deploy_overcloud"* ]]; then
     deploy_overcloud
    fi

done


