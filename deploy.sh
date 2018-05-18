#!/bin/bash

DIRNAME=`dirname $0`
SCRIPT_HOME=`realpath $DIRNAME`
DISK_POOL=/home/infrared_images

NAMESERVERS="10.16.36.29,10.11.5.19,10.5.30.160"
CHECKOUTS=${SCRIPT_HOME}/checkouts
OVERCLOUD_IMAGES=${SCRIPT_HOME}/downloaded_overcloud_images
INFRARED_CHECKOUT=${CHECKOUTS}/infrared
INFRARED_WORKSPACE_NAME=stack
INFRARED_WORKSPACE=${INFRARED_CHECKOUT}/.workspaces/${INFRARED_WORKSPACE_NAME}
ANSIBLE_PLAYBOOK=${INFRARED_CHECKOUT}/.venv/bin/ansible-playbook

COMBINED_HOSTS=${INFRARED_WORKSPACE}/combined_hosts

SETUP_CMDS="cleanup_infrared setup_infrared download_images"
BUILD_ENVIRONMENT_CMDS="rebuild_vms deploy_undercloud"

: ${CMDS:="${SETUP_CMDS} ${BUILD_ENVIRONMENT_CMDS} deploy_overcloud build_hosts deploy_stretch"}

: ${DEPLOY_STRETCH_TAGS:="ssh_keys,setup_routes,run_galera,run_clustercheck,create_vip,setup_haproxy,setup_keystone_db,setup_openstack_services"}
: ${DEPLOY_OVERCLOUD_TAGS:="setup_vlan,create_instackenv,install_vbmc,tune_undercloud,introspect_nodes,create_flavors,build_heat_config,prepare_containers,deploy_overcloud"}



RELEASE=queens
RELEASE_OR_MASTER=master
BUILD=current-tripleo-rdo-internal
RDO_OVERCLOUD_IMAGES="https://images.rdoproject.org/${RELEASE_OR_MASTER}/delorean/${BUILD}/"
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

    if  [ ! -f "ironic-python-agent.tar" ]; then
        curl -O ${RDO_OVERCLOUD_IMAGES}/ironic-python-agent.tar
    fi
    if  [ ! -f "overcloud-full.tar" ]; then
        curl -O ${RDO_OVERCLOUD_IMAGES}/overcloud-full.tar
    fi
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

    rm -f ${INFRARED_WORKSPACE}/stack?_hosts_* \
       ${COMBINED_HOSTS} \
       ${INFRARED_WORKSPACE}/hosts \
       ${INFRARED_WORKSPACE}/hosts-prov \
       ${INFRARED_WORKSPACE}/hosts-install \
       ${INFRARED_WORKSPACE}/ansible.ssh.config

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
        sudo virsh undefine $name --remove-all-storage;
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
        NODES="${NODES}s1undercloud:1,s1controller:3,s1compute:1,"
        #NODES="${NODES}s1undercloud:1,"
    fi

    if [[ "${STACKS}" == *"stack2"* ]]; then
        NODES="${NODES}s2undercloud:1,s2controller:3,s2compute:1,"
        #NODES="${NODES}s2undercloud:1,"
    fi

    # trim trailing comma
    NODES=${NODES:0:-1}

    # problem?  make sure to use public-images with undercloud
    #    --image-url https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2 \

    infrared_cmd virsh -vv \
        --disk-pool="${DISK_POOL}" \
        --topology-nodes="${NODES}" \
        --topology-network=stretch_nets \
        --topology-extend=yes \
        --host-key $HOME/.ssh/id_rsa  --host-address=127.0.0.2 \
        --image-url https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2 \

}

build_install_hosts() {
    # build out hostfiles for next steps.   different steps need a different
    # view of hosts.

    # build stack1-only hosts file
    cat ${INFRARED_WORKSPACE}/hosts-prov  | grep -e "^\[\\|s1\|localhost\|hypervisor" > ${INFRARED_WORKSPACE}/stack1_hosts_install

    # build stack2-only hosts file
    cat ${INFRARED_WORKSPACE}/hosts-prov  | grep -e "^\[\\|s2\|localhost\|hypervisor" > ${INFRARED_WORKSPACE}/stack2_hosts_install

}

build_combined_hosts() {
   cat /dev/null > ${COMBINED_HOSTS}

   grep ${INFRARED_WORKSPACE}/hosts-prov -e "\(localhost\|hypervisor\).*ansible" >> ${COMBINED_HOSTS}
   grep ${INFRARED_WORKSPACE}/hosts-prov -e "\(s1\|s2\)undercloud.*ansible" | sed 's/ansible_user=[[:alpha:]-]\+/ansible_user=stack/' >> ${COMBINED_HOSTS}
   grep ${INFRARED_WORKSPACE}/hosts-prov -e "\(s1\|s2\)\(controller\|compute\).*ansible" | sed 's/ansible_user=[[:alpha:]-]\+/ansible_user=heat-admin/' >> ${COMBINED_HOSTS}

   cat << EOF >> ${COMBINED_HOSTS}

[undercloud]
s1undercloud-0
s2undercloud-0

[master_overcloud]
s1controller-0
s1controller-1

[follower_overcloud]
s2controller-0
s2controller-1

[stack1]
s1undercloud-0
s1controller-0
s1controller-1
s1controller-2

[stack1_controller]
s1controller-0
s1controller-1
s1controller-2

[stack2]
s2undercloud-0
s2controller-0
s2controller-1
s2controller-2

[stack2_controller]
s2controller-0
s2controller-1
s2controller-2

[galera_nodes]
s1controller-0
s1controller-1
s2controller-0
s2controller-1

[pacemaker_control_nodes]
s1controller-0
s2controller-0

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

    # infrared only knows "queens", "rocky", or whatever, it doesn't know
    # "master".  various bits make it fetch "master" bits after that.
        # -e rr_release_name=${RELEASE} -e rr_master_release=NOTHING \

    infrared_cmd tripleo-undercloud -vv --version ${RELEASE} \
        --inventory=${LIMIT_HOSTFILE} \
        --build ${BUILD} \
        -e rr_use_public_repos=true \
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
        ANSIBLE_HOSTS=${INFRARED_WORKSPACE}/stack1_hosts_undercloud
    fi

    if [[ $STACK == "stack2" ]]; then
        PROVISIONING_IP_PREFIX=192.168.25
        ANSIBLE_HOSTS=${INFRARED_WORKSPACE}/stack2_hosts_undercloud
    fi

        pushd ${SCRIPT_HOME}
        ${ANSIBLE_PLAYBOOK} -vv \
            -i ${ANSIBLE_HOSTS} \
            --tags "${DEPLOY_OVERCLOUD_TAGS}" \
            -e release_name=${RELEASE} \
            -e container_namespace=${RELEASE_OR_MASTER} \
            -e container_tag=${BUILD} \
            -e undercloud_network_cidr=${PROVISIONING_IP_PREFIX}.0/24 \
            -e rh_stack_name="${STACK}" \
            -e working_dir=/home/stack \
            playbooks/deploy_overcloud.yml
        popd

}

deploy_stretch_cluster() {
    pushd ${SCRIPT_HOME}
    ${ANSIBLE_PLAYBOOK} -vv \
        -i ${COMBINED_HOSTS} \
        --tags "${DEPLOY_STRETCH_TAGS}" \
        playbooks/deploy_stretch_galera.yml
    popd


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
    build_install_hosts
    upload_images
fi


for stack_arg in $STACKS ; do
    STACK="${stack_arg}"

    if [[ "${CMDS}" == *"deploy_undercloud"* ]]; then
     deploy_undercloud
    fi
done

for stack_arg in $STACKS ; do
    STACK="${stack_arg}"

    if [[ "${CMDS}" == *"deploy_overcloud"* ]]; then
     deploy_overcloud
    fi

done

if [[ "${CMDS}" == *"build_hosts"* ]]; then
    build_combined_hosts
fi

if [[ "${CMDS}" == *"deploy_stretch"* ]]; then
    deploy_stretch_cluster
fi
