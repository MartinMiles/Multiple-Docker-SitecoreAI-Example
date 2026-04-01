# escape=`

#
# Development-only image for running Next.js in a containerized environment.
# Assumes that the Next.js rendering host source is mounted to c:\app.
#

ARG PARENT_IMAGE
FROM ${PARENT_IMAGE} as debug

USER ContainerAdministrator

WORKDIR /app

EXPOSE 3000
#ENTRYPOINT "npm install && npm run dev"
ENTRYPOINT "npm install && npm run dev"