#!/usr/bin/env bash

USAGE="""
USAGE:

        bash start.sh

        See README.md for more information.
"""

DATE="$( date +%Y-%m-%d-%H-%M-%S )"
STDOUT_FILE="./logs/start_STDOUT_${DATE}.log"
STDERR_FILE="./logs/start_STDERR_${DATE}.log"

if ! source ./config.bash ; then
	echo "ERROR: Cannot source config.bash. Exiting."
	echo "${USAGE}"
	exit 1
fi

if [ ! -e "acme/acme.json" ] ; then
	echo """
WARNING!

Your setup does not already have the file acme/acme.json.

If you need to, please copy your existing one in. 

  - Note that you will sometimes need to modify the acme.json if this is a big version change.
    Please consult the Traefik and Let's Encrypt documentation.

Traefik will make a new one for you if that is needed, but this repo cannot help you ensure success.

  - If you need this, find the location of the staging resolver in docker-compose.traefik.swarm.yml
    Definitely examine the documentation in Traefik and Let's Encrypt and modify as needed.
"""	
	if [ ! -d "acme" ] ; then
		echo """
  - If you are ready to have Traefik make the file acme.json for you, this script will make the directory.
    In that case, just hit enter below.
"""
	fi
	echo """
Please use cntrl-C to exit if you are not ready to proceed. 
Otherwise, hit enter and the script will proceed.
"""
        read answer
fi

for DIR in "logs" "ACCESS_LOGS" "acme" ; do
if [ ! -d "${DIR}" ] ; then
	COMMAND="mkdir -p ${DIR}"
	echo "The command to be run is:
	${COMMAND}" 
	if [ "${TEST}" != "YES" ] ; then
		eval ${COMMAND} | tee ${STDOUT_FILE}
		result="$?"
		if [ "${result}" != "0" ] ; then
			echo "Something went wrong with the previous command. Exiting." | tee ${STDERR_FILE}
		fi
	fi
fi
done


COMMAND="""
docker stack deploy \
	--compose-file docker-compose.traefik.swarm.yml \
	traefik \
	        2>> ${STDERR_FILE} \
        >> ${STDOUT_FILE}
"""
#COMMAND="docker --version"  # uncomment to test workflows when TEST is not YES
echo "The command to be run is:
${COMMAND}" 
if [ "${TEST}" != "YES" ] ; then
	eval ${COMMAND} | tee ${STDOUT_FILE}
	result="$?"
	if [ "${result}" != "0" ] ; then
		echo "Something went wrong with the previous command. Exiting." | tee ${STDERR_FILE}
	fi
fi
