#!/bin/bash
echo $(date) " - Starting Infra / Node Prep Script"

USERNAME_ORG=$1
PASSWORD_ACT_KEY="$2"
POOL_ID=$3
KATELLO_CA="$4"

# Remove RHUI

rm -f /etc/yum.repos.d/rh-cloud.repo
sleep 10

# Install Katello CA for Private Satellite
echo $(date) " - Install Katello CA rpm"
yum -y --nogpgcheck install "$KATELLO_CA"
    
# Register with Satellite Server
echo $(date) " - Register host with Satellite Server"
subscription-manager register --activationkey="$PASSWORD_ACT_KEY" --org="$USERNAME_ORG"

if [ $? -eq 0 ]
then
    echo "Subscribed successfully"
elif [ $? -eq 64 ]
then
    echo "This system is already registered."
else
    echo "Incorrect Username / Password or Organization ID / Activation Key specified"
    exit 3
fi

subscription-manager register  > attach.log
if [ $? -eq 0 ]
then
    echo "Pool attached successfully"
else
    evaluate=$( cut -f 2-5 -d ' ' attach.log )
    if [[ $evaluate == "unit has already had" ]]
    then
        echo "Pool $POOL_ID was already attached and was not attached again."
    else
        echo "Incorrect Pool ID or no entitlements available"
        exit 4
    fi
fi

# Disable all repositories and enable only the required ones
echo $(date) " - Disabling all repositories and enabling only the required repos"

subscription-manager repos --disable="*"

subscription-manager repos \
    --enable="rhel-7-server-rpms" \
    --enable="rhel-7-server-extras-rpms" \
    --enable="rhel-7-server-ose-3.9-rpms" \
    --enable="rhel-7-server-ansible-2.4-rpms" \
    --enable="rhel-7-fast-datapath-rpms" \
    --enable="rh-gluster-3-client-for-rhel-7-server-rpms"

# Install base packages and update system to latest packages
echo $(date) " - Install base packages and update system to latest packages"

yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct
yum -y install cloud-utils-growpart.noarch
yum -y install ansible
yum -y update glusterfs-fuse
yum -y update --exclude=WALinuxAgent

# Excluders for OpenShift
yum -y install atomic-openshift-excluder atomic-openshift-docker-excluder
atomic-openshift-excluder unexclude

# Grow Root File System
echo $(date) " - Grow Root FS"

rootdev=`findmnt --target / -o SOURCE -n`
rootdrivename=`lsblk -no pkname $rootdev`
rootdrive="/dev/"$rootdrivename
name=`lsblk  $rootdev -o NAME | tail -1`
part_number=${name#*${rootdrivename}}

growpart $rootdrive $part_number -u on
xfs_growfs $rootdev

# Install Docker
echo $(date) " - Installing Docker"
yum -y install docker

# Update docker storage
echo "
# Adding insecure-registry option required by OpenShift
OPTIONS=\"\$OPTIONS --insecure-registry 172.30.0.0/16\"
" >> /etc/sysconfig/docker

# Create thin pool logical volume for Docker
echo $(date) " - Creating thin pool logical volume for Docker and staring service"

DOCKERVG=$( parted -m /dev/sda print all 2>/dev/null | grep unknown | grep /dev/sd | cut -d':' -f1 | head -n1 )

echo "
# Adding OpenShift data disk for docker
DEVS=${DOCKERVG}
VG=docker-vg
" >> /etc/sysconfig/docker-storage-setup

# Running setup for docker storage
docker-storage-setup
if [ $? -eq 0 ]
then
    echo "Docker thin pool logical volume created successfully"
else
    echo "Error creating logical volume for Docker"
    exit 5
fi

# Enable and start Docker services

systemctl enable docker
systemctl start docker

echo $(date) " - Script Complete"

