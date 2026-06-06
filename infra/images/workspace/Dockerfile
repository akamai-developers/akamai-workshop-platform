# Generic workspace image for akamai-workshop-platform.
# Bakes NO workshop content — code-server + python3 + git + startup.sh only.
# Content is cloned at pod startup by startup.sh (from $CONTENT_REPO), so one image
# serves any workshop. Building this image is OPTIONAL: the platform also runs the
# stock codercom/code-server image with startup.sh mounted from a ConfigMap.
FROM codercom/code-server:latest

USER root

RUN apt-get update && \
    apt-get install -y python3 python3-venv python3-pip git curl && \
    rm -rf /var/lib/apt/lists/*

# Pre-install the Python extension so the workshop's .py files get language support.
USER coder
RUN code-server --install-extension ms-python.python

# The clone-at-startup script is the entrypoint. Same script the ConfigMap path uses.
COPY startup.sh /usr/local/bin/startup.sh

EXPOSE 8080
ENTRYPOINT ["/bin/bash", "/usr/local/bin/startup.sh"]
