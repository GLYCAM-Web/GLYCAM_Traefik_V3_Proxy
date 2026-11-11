#!/usr/bin/env bash

USAGE="""
USAGE:

        bash stop.sh

        See README.md for more information.
"""

DATE="$( date +%Y-%m-%d-%H-%M-%S )"
mkdir -p ./logs
STDOUT_FILE="./logs/stop_STDOUT_${DATE}.log"
STDERR_FILE="./logs/stop_STDERR_${DATE}.log"

COMMAND="""
docker stack rm \
	traefik \
        2>> ${STDERR_FILE} \
        >> ${STDOUT_FILE}
"""
echo "The command to be run is:
${COMMAND}"
if [ "${TEST}" != "YES" ] ; then
	docker stack rm traefik >> "${STDOUT_FILE}" 2>> "${STDERR_FILE}"
	result="$?"
	cat "${STDOUT_FILE}"
	if [ "${result}" != "0" ] ; then
		echo "Something went wrong with the previous command. Exiting." | tee -a "${STDERR_FILE}"
		exit "${result}"
	fi
fi
