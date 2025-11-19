#!/usr/bin/env bash

USAGE="""
USAGE:

        bash start.sh

        See README.md for more information.
"""

DATE="$( date +%Y-%m-%d-%H-%M-%S )"
STDOUT_FILE="./logs/start_STDOUT_${DATE}.log"
STDERR_FILE="./logs/start_STDERR_${DATE}.log"

COMMAND="""
docker stack rm \
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
