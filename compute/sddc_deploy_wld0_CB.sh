#!/bin/bash
#goldyck@vmware.com

# $1 : cPod Name
# This scrips deploys a VCF management domain using an already deployed cloudbuilder.

# source helper functions
. ./env
source ./extra/functions.sh
source ./extra/functions_sddc_mgr.sh

#input validation check
if [ $# -ne 1 ]; then
  echo "usage: $0 <name_of_cpod>"
  echo "usage example: $0 LAB01 4 vedw" 
  exit
fi

#build the variables
CPODROUTER=$( echo "${HEADER}-${1}" | tr '[:upper:]' '[:lower:]' )
CPOD_NAME=$( echo "${1}" | tr '[:lower:]' '[:upper:]' )
NAME_LOWER=$( echo "${HEADER}"-"${CPOD_NAME}" | tr '[:upper:]' '[:lower:]' )
VLAN=$( grep -m 1 "${NAME_LOWER}\s" /etc/hosts | awk '{print $1}' | cut -d "." -f 4 )
VLAN_MGMT="${VLAN}"
SUBNET=$( ./"${COMPUTE_DIR}"/cpod_ip.sh "${1}" )
PASSWORD=$( ${EXTRA_DIR}/passwd_for_cpod.sh ${CPOD_NAME} ) 
SCRIPT_DIR=/tmp/scripts
SCRIPT=/tmp/scripts/cloudbuilder-${NAME_LOWER}.json

if [ ! -f "$SCRIPT" ]; then
    echo "$SCRIPT does not exist."
	exit 1
fi

TIMEOUT=0

# with NSX, VLAN Management is untagged
if [ ${BACKEND_NETWORK} != "VLAN" ]; then
	VLAN_MGMT="0"
fi

if [ ${VLAN} -gt 40 ]; then
	VMOTIONVLANID=${VLAN}1
	VSANVLANID=${VLAN}2
	TRANSPORTVLANID=${VLAN}3
else
	VMOTIONVLANID=${VLAN}01
	VSANVLANID=${VLAN}02
	TRANSPORTVLANID=${VLAN}03
fi

#make the curl more readable
URL="https://cloudbuilder.${NAME_LOWER}.${ROOT_DOMAIN}"
AUTH="admin:${PASSWORD}"

#check if the script already exists
if [ ! -f "${SCRIPT}" ]; then
  echo "Error: EMS json ${SCRIPT} does not exist"
  exit 1
fi

while [ -z "$APICHECK" ]
do  
	echo "checking if the API on cloudbuilder ${URL} is ready yet..."
	APICHECK=$(curl -s -k -u ${AUTH} -X GET ${URL}/v1/sddcs/validations)
	sleep 10
	TIMEOUT=$((TIMEOUT + 1))
	if [ $TIMEOUT -ge 48 ]; then
		echo "bailing out..."
		exit 1
	fi 
done

#sleep a bit to avoid API issues
echo "sleeping a bit to make sure the API is ready."
sleep 10

echo "API on cloudbuilder ${URL} is ready..."

echo
echo "Checking running validations"
VALIDATIONLIST=$(cloudbuilder_check_validation_list  "${NAME_LOWER}" "${PASSWORD}")
#echo "${VALIDATIONLIST}"
VALIDATIONINPROGRESS=$(echo "$VALIDATIONLIST" | jq '. |select (.status == "IN_PROGRESS")| .id')
if [ "$VALIDATIONINPROGRESS" != "" ]
then
	echo "Current validation in progress ID : $VALIDATIONINPROGRESS"
	echo "Bailing out ..."
	exit 1
else
	echo "thunderbirds are go!"
fi
#validate the EMS.json - for some reason this has to be done in 2 steps

VALIDATIONID=$(curl -s -k -u ${AUTH} -H 'Content-Type: application/json' -H 'Accept: application/json' -d @${SCRIPT} -X POST ${URL}/v1/sddcs/validations)
#echo "The validation returns: ${VALIDATIONID}"
VALIDATIONID=$(echo $VALIDATIONID | jq -r .id)
#echo "The validation after jq returns: ${VALIDATIONID}"
if [ -z "$VALIDATIONID" ]; then
  echo "Error: The validation ID is empty..."
  exit 1
fi
echo "The validation with id: ${VALIDATIONID} has started"
echo 
cloudbuilder_loop_wait_validation_status "${NAME_LOWER}" "${PASSWORD}" "${VALIDATIONID}"

#proceeding with deployment
echo "Proceeding with Bringup using ${SCRIPT}."

BRINGUPID=$(curl -s -k -u ${AUTH} -H 'Content-Type: application/json' -H 'Accept: application/json' -d @${SCRIPT} -X POST ${URL}/v1/sddcs | jq -r '.id')

if [ -z "$BRINGUPID" ]; then
  echo "Error: The bringup id  is empty..."
  exit 1
fi

echo "The deployment with id: ${BRINGUPID} has started"

echo
cloudbuilder_loop_wait_deployment_status "${NAME_LOWER}" "${PASSWORD}" "${BRINGUPID}"

echo "all done... do i get a cookie now?"
