# Example Files for Service-Side Routing Definitions

These definitions allow for complex rate-limiting. 

Specifically:

- Website traffic that is not related to the JSON API is not limited.

- JSON API traffic that is part of a browser session on the website has generous limits.
  This is determined by ensuring that the Referer is the website.

- JSON API traffic from a script or from another website is limited as follows:

    - When requesting a new service (anything that uses the POST method), the max is one per 10 seconds.

    - When requesting information, for example the status of a service request, the max is one per second.


The files here are not the complete set of what you need. 
They only describe the parts used by Docker to allow and configure proxy via Traefik.

They should be loaded in the order they appear here. 
The names are chosen so that the ordering is also alphabetical.

1. `docker-compose.proxy.swarm.base.port.yml`

    This one isn't strictly relevant to Traefik. But, it is useful to be able to get a page from your 
    website from the command line of a swarm host. For example, you can use this to determine if a lack of
    a website is due to the site itself not functioning or if your Traefik is misconfigured. This file
    contains that information. It also shows how to set a number of replicas.

    Note! If you want more than one replica, do not have Traefik log to a file (as the setup here does).

    Instead, deploy a cloud-native logging stack/service. Examples are the ELK stack and the Grafana-Loki
    with Promtail stack.

2. `docker-compose.proxy.swarm.traefik.https.yml`

    This file will enable https traffic. It will also redirect any http requests to https. You can use this
    file without the next file. Note that definitions in the next file will override some in this file.

    The assigned priorities are necessary for the rate limiting to work, but they also ensure that requests
    that come in on https are routed immediately.

3. `docker-compose.proxy.swarm.traefik.ratelimits.yml`

    This file contains configurations that implement the rate limiting described above. Note that two of the
    definitions override their counterparts in the previous file. This file must be loaded after that one.

