#!/bin/bash

DIRNAME=`dirname $0`
SCRIPT_HOME=`realpath $DIRNAME`
DISK_POOL=/home/infrared_images

NAMESERVERS="10.16.36.29,10.11.5.19,10.5.30.160"
CHECKOUTS=${SCRIPT_HOME}/checkouts
OVERCLOUD_IMAGES=${SCRIPT_HOME}/downloaded_overcloud_images
INFRARED_CHECKOUT=${CHECKOUTS}/infrared

#INFRARED_REVISION="master"
INFRARED_REVISION="31370846e54bec15d816cf3f3e923f0d74fa16a5"

INFRARED_WORKSPACE_NAME=stack
INFRARED_WORKSPACE=${INFRARED_CHECKOUT}/.workspaces/${INFRARED_WORKSPACE_NAME}
ANSIBLE_PLAYBOOK=${INFRARED_CHECKOUT}/.venv/bin/ansible-playbook

COMBINED_HOSTS=${INFRARED_WORKSPACE}/combined_hosts

SETUP_CMDS="cleanup_infrared setup_infrared download_images patch_images"
BUILD_ENVIRONMENT_CMDS="rebuild_vms build_hosts deploy_undercloud setup_routes"

: ${CMDS:="${SETUP_CMDS} ${BUILD_ENVIRONMENT_CMDS} deploy_overcloud"}

: ${SETUP_ROUTES_TAGS:="setup_routes"}
: ${DEPLOY_OVERCLOUD_TAGS:="hack_tripleo,gen_ssh_key,setup_vlan,create_instackenv,install_vbmc,tune_undercloud,introspect_nodes,create_flavors,build_heat_config,prepare_containers,run_deploy_overcloud"}



RELEASE=stein
RELEASE_OR_MASTER=master
#BUILD=current-tripleo-rdo-internal
BUILD=current-tripleo
RDO_OVERCLOUD_IMAGES="https://images.rdoproject.org/${RELEASE_OR_MASTER}/delorean/${BUILD}/"
IMAGE_URL="file:///tmp/"

set -e
set -x


getinput() {
  local prompt="$1"
  local input=''

  set +x
  echo "${prompt}"
  while [ "1" ];  do
  read -rsn1 input
  case "$input" in
      Y) set -x; YESNO=1; return;;
      n) set -x; YESNO=0; return;;
      *) echo "please answer Y or n"
  esac
  done
}


cleanup_infrared() {
    getinput "WARNING!  Will wipe out the entire infrared checkout, including all infrared hostfiles, ansible will no longer be able to run against current VMs, (Y)es/(n)o"

    if [ "$YESNO" = "1" ]; then
        rm -fr ${INFRARED_CHECKOUT}
    else
        exit -1
    fi
}

setup_infrared() {
    SYSTEM_PYTHON_2=/usr/bin/python2

    # sudo yum install git gcc libffi-devel openssl-devel python-virtualenv libselinux-python

    mkdir -p ${CHECKOUTS}

    if [ ! -d ${INFRARED_CHECKOUT} ]; then
        git clone https://github.com/redhat-openstack/infrared.git ${INFRARED_CHECKOUT}
        pushd ${INFRARED_CHECKOUT}
        git checkout ${INFRARED_REVISION}
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

patch_images() {

    TEMPDIR=$(mktemp -d)
    pushd $TEMPDIR
    tar -xf ${OVERCLOUD_IMAGES}/${RELEASE}/overcloud-full.tar
    chmod 755 ${SCRIPT_HOME}/roles/deploy-overcloud/files/stretch_galera
    chmod 755 ${SCRIPT_HOME}/roles/deploy-overcloud/files/galera
    virt-copy-in -a overcloud-full.qcow2 \
         ${SCRIPT_HOME}/roles/deploy-overcloud/files/stretch_galera \
         ${SCRIPT_HOME}/roles/deploy-overcloud/files/galera \
         /usr/lib/ocf/resource.d/heartbeat/
    # it's important the tar file has no directory info in it,
    # like ./ .  infrared and probably others assume this is not
    # present.
    tar -cf ${OVERCLOUD_IMAGES}/${RELEASE}/overcloud-full.tar *
    popd
    rm -fr $TEMPDIR
}


reset_workspace() {
    getinput "WARNING!  Will wipe out the infrared workspace, which erases all infrared hostfiles, ansible will no longer be able to run against current VMs, (Y)es/(n)o "

    if [ "$YESNO" == "1" ]; then
        rm -fr ${INFRARED_WORKSPACE}
    else
       exit -1
    fi
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
s1controller-2
s2controller-0
s2controller-1
s2controller-2

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

    # these were renamed to "host" in https://github.com/openstack/instack-undercloud/commit/9c6424df5d9d0cb41ec78cbdddb520f1c1ec604b
    #    --config-options DEFAULT.undercloud_public_vip=${PROVISIONING_IP_PREFIX}.2 \
    #    --config-options DEFAULT.undercloud_admin_vip=${PROVISIONING_IP_PREFIX}.3 \

    # dont use ssl, but then the docker stuff fails
    #    --config-options DEFAULT.generate_service_certificate=false \

    # container_images file works around issue I described at:
    # https://review.gerrithub.io/c/redhat-openstack/infrared/+/417795/16/plugins/tripleo-undercloud/templates/undercloud.conf.j2#37
    infrared_cmd tripleo-undercloud -vv --version ${RELEASE} \
        --inventory=${LIMIT_HOSTFILE} \
        --build ${BUILD} \
        -e rr_use_public_repos=true \
        -e rr_release_name=master \
        --config-options DEFAULT.enable_telemetry=false \
        --config-options DEFAULT.local_ip=${PROVISIONING_IP_PREFIX}.1/24 \
        --config-options DEFAULT.undercloud_public_host=${PROVISIONING_IP_PREFIX}.2 \
        --config-options DEFAULT.undercloud_admin_host=${PROVISIONING_IP_PREFIX}.3 \
        --config-options DEFAULT.gateway=${PROVISIONING_IP_PREFIX}.1 \
        --config-options ctlplane-subnet.gateway=${PROVISIONING_IP_PREFIX}.1 \
        --config-options DEFAULT.cidr=${PROVISIONING_IP_PREFIX}.0/24 \
        --config-options ctlplane-subnet.cidr=${PROVISIONING_IP_PREFIX}.0/24 \
        --config-options DEFAULT.masquerade_network=${PROVISIONING_IP_PREFIX}.0/24 \
        --config-options DEFAULT.dhcp_start=${PROVISIONING_IP_PREFIX}.5 \
        --config-options ctlplane-subnet.dhcp_start=${PROVISIONING_IP_PREFIX}.5 \
        --config-options DEFAULT.dhcp_end=${PROVISIONING_IP_PREFIX}.24 \
        --config-options ctlplane-subnet.dhcp_end=${PROVISIONING_IP_PREFIX}.24 \
        --config-options DEFAULT.inspection_iprange=${PROVISIONING_IP_PREFIX}.100,${PROVISIONING_IP_PREFIX}.120 \
        --config-options ctlplane-subnet.inspection_iprange=${PROVISIONING_IP_PREFIX}.100,${PROVISIONING_IP_PREFIX}.120 \
        --config-options DEFAULT.undercloud_nameservers="${NAMESERVERS}" \
        --config-options DEFAULT.container_images_file="" \
        --images-task import --images-url ${IMAGE_URL}

    cp ${INFRARED_WORKSPACE}/hosts ${WRITE_HOSTFILE}
}

deploy_overcloud() {
    if [[ "${STACKS}" == *"stack1"* ]]; then
        ANSIBLE_HOSTS=${INFRARED_WORKSPACE}/stack1_hosts_undercloud
        SPECIFY_STACK=" -e rh_stack_name=stack1"
    fi

    if [[ "${STACKS}" == *"stack2"* ]]; then
        ANSIBLE_HOSTS=${INFRARED_WORKSPACE}/stack2_hosts_undercloud
        SPECIFY_STACK=" -e rh_stack_name=stack2"
    fi

    if [[ "${STACKS}" == *"stack1"* && "${STACKS}" == *"stack2"* ]]; then
	ANSIBLE_HOSTS="${COMBINED_HOSTS}"
        SPECIFY_STACK=""
    fi

    pushd ${SCRIPT_HOME}
    ${ANSIBLE_PLAYBOOK} -vv \
        -i ${ANSIBLE_HOSTS} \
        --tags "${DEPLOY_OVERCLOUD_TAGS}" \
        -e release_name=${RELEASE} \
        -e container_namespace=${RELEASE_OR_MASTER} \
        -e container_tag=${BUILD} \
        -e working_dir=/home/stack ${SPECIFY_STACK} \
        playbooks/deploy_overcloud.yml
    popd

}

setup_routes() {
    pushd ${SCRIPT_HOME}
    ${ANSIBLE_PLAYBOOK} -vv \
        -i ${COMBINED_HOSTS} \
        --tags "${SETUP_ROUTES_TAGS}" \
        playbooks/deploy_undercloud_routes.yml
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

if [[ "${CMDS}" == *"patch_images"* ]]; then
    patch_images
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

if [[ "${CMDS}" == *"build_hosts"* ]]; then
    build_combined_hosts
fi

for stack_arg in $STACKS ; do
    STACK="${stack_arg}"

    if [[ "${CMDS}" == *"deploy_undercloud"* ]]; then
     deploy_undercloud
    fi
done


if [[ "${CMDS}" == *"setup_routes"* ]]; then
    setup_routes
fi



if [[ "${CMDS}" == *"deploy_overcloud"* ]]; then
 deploy_overcloud
fi


