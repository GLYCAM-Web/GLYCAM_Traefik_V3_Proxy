#!/usr/bin/env bash

USAGE="""
USAGE:

        bash start.sh

        See README.md for more information.
"""

DATE="$( date +%Y-%m-%d-%H-%M-%S )"
STDOUT_FILE="./logs/start_STDOUT_${DATE}.log"
STDERR_FILE="./logs/start_STDERR_${DATE}.log"

if [ ! -f ./config.bash ] ; then
	echo "ERROR: config.bash not found. Copy config.bash.example to config.bash and edit it."
	echo "${USAGE}"
	exit 1
fi

# Restrict permissions on config.bash since it holds GRAFANA_ADMIN_PASSWORD
chmod 600 ./config.bash 2>/dev/null || true

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
        read -r answer
fi

for DIR in "logs" "ACCESS_LOGS" "acme" "logging/geoip" "logging/data/victorialogs" "logging/data/vector" "logging/data/grafana" ; do
	if [ ! -d "${DIR}" ] ; then
		echo "The command to be run is:
	mkdir -p ${DIR}"
		if [ "${TEST}" != "YES" ] ; then
			mkdir -p "${DIR}"
			result="$?"
			if [ "${result}" != "0" ] ; then
				echo "Something went wrong creating ${DIR}. Exiting." | tee -a "${STDERR_FILE}"
				exit 1
			fi
		fi
	fi
done

# Ensure strict permissions on acme directory and acme.json (required by Traefik for TLS private keys)
if [ "${TEST}" != "YES" ] ; then
	chmod 700 acme 2>/dev/null || true
	if [ -f "acme/acme.json" ] ; then
		chmod 600 acme/acme.json 2>/dev/null || true
	fi
	# Create an empty git-ignored local IP filter file if none exists yet
	if [ ! -f "logging/internal_ips.local.conf" ] && [ -f "logging/internal_ips.example.conf" ] ; then
		cp "logging/internal_ips.example.conf" "logging/internal_ips.local.conf"
	fi
fi

COMPOSE_ARGS=(--compose-file docker-compose.traefik.swarm.yml)
LOGGING_COMPOSE_DISPLAY="--compose-file docker-compose.logging.swarm.yml"
if [ "${ENABLE_LOGGING_STACK:-YES}" = "NO" ] ; then
	LOGGING_COMPOSE_DISPLAY=""
else
	if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ] ; then
		echo "ERROR: GRAFANA_ADMIN_PASSWORD is not set in config.bash."
		echo "Please add: export GRAFANA_ADMIN_PASSWORD='your-strong-password' to config.bash"
		echo "(or set export ENABLE_LOGGING_STACK='NO' to disable Grafana/VictoriaLogs)."
		exit 1
	fi
	COMPOSE_ARGS+=(--compose-file docker-compose.logging.swarm.yml)
fi

COMMAND="""
docker stack deploy \
	--compose-file docker-compose.traefik.swarm.yml \
	${LOGGING_COMPOSE_DISPLAY} \
	traefik \
	        2>> ${STDERR_FILE} \
        >> ${STDOUT_FILE}
"""
echo "The command to be run is:
${COMMAND}"
if [ "${TEST}" != "YES" ] ; then
	docker stack deploy "${COMPOSE_ARGS[@]}" traefik >> "${STDOUT_FILE}" 2>> "${STDERR_FILE}"
	result="$?"
	cat "${STDOUT_FILE}"
	if [ "${result}" != "0" ] ; then
		echo "Something went wrong with the previous command. Exiting." | tee -a "${STDERR_FILE}"
		exit "${result}"
	fi
fi
