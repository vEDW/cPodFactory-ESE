#!/bin/bash
#jacobssimon@vmware.com
#modified by : edewitte@vmware.com

# ELM
# export PSC_DOMAIN
# export PSC_PASSWORD

source ./env

if [ ! -f ./licenses.key ]; then
	echo "./licenses.key does not exist. please create one by using the licenses.key.template as reference"
	exit 1
else
	source ./licenses.key
fi

[ "$1" == "" ] && echo "usage: $0 <name of cpod>, then the script automatically license vCenter, vSphere and vSAN if any" && exit 1

#==========CONNECTION DETAILS==========

NAME="$( echo ${1} | tr '[:lower:]' '[:upper:]' )"
POD_NAME="cPod-${1}"
POD_NAME_LOWER="$( echo ${POD_NAME} | tr '[:upper:]' '[:lower:]' )"
POD_FQDN="${POD_NAME_LOWER}.${ROOT_DOMAIN}"

if [ -z ${PSC_DOMAIN} ]; then
	export GOVC_USERNAME="administrator@${POD_FQDN}"
else
	export GOVC_USERNAME="administrator@${PSC_DOMAIN}"
fi

if [ -z ${PSC_DOMAIN} ]; then
	export GOVC_PASSWORD="$( ./extra/passwd_for_cpod.sh ${1} )"
else
	export GOVC_PASSWORD="${PSC_PASSWORD}"
	VCENTER_CPOD_PASSWD=${PSC_PASSWORD}
fi

export GOVC_URL="https://${GOVC_USERNAME}:${GOVC_PASSWORD}@vcsa.${POD_FQDN}"
export GOVC_DATACENTER=""

#======================================
# Local Functions

add_licenses() {
	echo 
	echo "Adding licenses to vCenter"
	echo
	govc license.add $VCENTER_KEY
	govc license.add $ESX_KEY
	govc license.add $VSAN_KEY
	govc license.add $TANZU_KEY
	#govc license.ls
}

apply_license_vcenter() {
	echo 
	echo "Applying vCenter license"
	echo 
	govc license.assign -host="" -name="vcsa.${POD_FQDN}" $VCENTER_KEY
}

apply_licenses_hosts() {
	echo 
	echo "Applying hosts licenses"
	echo 
	HOSTS=$(govc find . -type h|cut -d "/" -f5)
	for HOST in $HOSTS;
	do
		govc license.assign -host ${HOST,,} ${ESX_KEY}
	done
}

apply_licenses_clusters() {
	echo 
	echo "Applying VSAN licenses"
	echo 
	CLUSTERS=$(govc ls -t ClusterComputeResource host |cut -d "/" -f4)
	for CLUSTER in $CLUSTERS;
	do
		govc license.assign -host="" -cluster $CLUSTER $VSAN_KEY
	done
}

apply_licenses_tanzu() {
	echo 
	echo "Applying TANZU licenses"
	echo 
	CLUSTERS=$(govc license.assigned.ls |grep wcp | awk '{print $3}')
	for CLUSTER in $CLUSTERS;
	do
		govc license.assign -host="" -name=$CLUSTER $TANZU_KEY
	done
}

remove_eval_license() {
	echo 
	echo "Removing Eval license if applicable "
	echo 
	TESTEVAL=$(govc license.ls |grep -c "00000")
	if [[ ${TESTEVAL} -gt 0 ]];
	then
		govc license.remove "00000-00000-00000-00000-00000"
	fi
}

add_and_apply_licenses() {
		add_licenses
		apply_license_vcenter
		apply_licenses_hosts
		apply_licenses_clusters
		# apply_licenses_tanzu - govc does not yet support assigning tanzu keys.
		remove_eval_license
		govc license.assigned.ls
}

check_license_file(){
	if [[ $(cat ./licenses.key |grep $1 |grep XXXXX |wc -l) > 0 ]]; then
		echo "./licenses.key includes undefined license keys :"
		cat ./licenses.key |grep $1 |grep XXXXX 
		exit 1
	fi 
}
#======================================

VCENTER_VERSION=$(govc about |grep Version | awk '{print $2}' |cut -d "." -f1)

DATACENTERS=$(govc find . -type d)

case $VCENTER_VERSION in
	7)
		check_license_file "V7"
		echo "Applying Version 7"
		VCENTER_KEY=$V7_VCENTER_KEY
		ESX_KEY=$V7_ESX_KEY
		VSAN_KEY=$V7_VSAN_KEY
		TANZU_KEY=$V7_TANZU_KEY
		add_and_apply_licenses
		;;
	8)
		check_license_file "V8"
		echo "Applying Version 8"
		VCENTER_KEY=$V8_VCENTER_KEY
		ESX_KEY=$V8_ESX_KEY
		VSAN_KEY=$V8_VSAN_KEY
		TANZU_KEY=$V8_TANZU_KEY
		add_and_apply_licenses
		;;
	*)
		echo "Version $VCENTER_VERSION not foreseen yet by script"
		;;
esac
