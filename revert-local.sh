#!/bin/bash
set -euo pipefail

OVERRIDE_FILE="${HOME}/.config/incus-spawn/images/minimal.yaml"

if [ -f "${OVERRIDE_FILE}" ]; then
  rm "${OVERRIDE_FILE}"
  echo "Removed ${OVERRIDE_FILE}"
  echo "isx will use the built-in base image on the next build."
else
  echo "No override found — isx is already using the built-in base image."
fi
