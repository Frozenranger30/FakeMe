#!/bin/bash
# Installs FakeMeDAL.plugin → /Library/CoreMediaIO/Plug-Ins/DAL/
# Requires admin password (sudo) — but NO Developer Account.
# After install, the virtual camera appears in Zoom, Teams, FaceTime etc.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="${SCRIPT_DIR}/.."
BUNDLE="${PROJECT_DIR}/FakeMeDAL.plugin"
INSTALL_DIR="/Library/CoreMediaIO/Plug-Ins/DAL"

if [ ! -d "${BUNDLE}" ]; then
  echo "FakeMeDAL.plugin not found. Building first..."
  bash "${SCRIPT_DIR}/build_dal_plugin.sh"
fi

echo "Installing to ${INSTALL_DIR} (requires sudo)..."
sudo mkdir -p "${INSTALL_DIR}"
sudo cp -r "${BUNDLE}" "${INSTALL_DIR}/"
echo "Installed: ${INSTALL_DIR}/FakeMeDAL.plugin"
echo ""
echo "Now start FakeMe.app — the virtual camera will appear in Zoom / Teams / FaceTime."
echo "To uninstall:  sudo rm -rf '${INSTALL_DIR}/FakeMeDAL.plugin'"
