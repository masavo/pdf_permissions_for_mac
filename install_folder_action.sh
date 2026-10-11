#!/usr/bin/env bash
set +x +v
set -eu
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="${SCRIPT_DIR}/folder-action.applescript"
DEST_DIR="${FOLDER_ACTION_SCRIPTS_DIR:-${HOME}/Library/Scripts/Folder Action Scripts}"
DEST_SCRIPT="${DEST_DIR}/PDF自動権限付与.scpt"

if [[ $# -gt 0 ]] && [[ $# -ne 2 || "$1" != --attach ]]; then
  echo 'Usage: install_folder_action.sh [--attach /absolute/path/to/folder]' >&2
  exit 2
fi
if [[ $# -eq 2 ]] && [[ "$2" != /* || ! -d "$2" ]]; then
  echo 'The watched folder must be an existing absolute path.' >&2
  exit 2
fi

mkdir -p "${DEST_DIR}"
temp="$(mktemp "${DEST_DIR}/.pdf-permissions-install.XXXXXX")"
trap 'rm -f "${temp}" "${temp}.scpt"' EXIT
secure_path="${SCRIPT_DIR}/secure_pdf.sh"
secure_path="${secure_path//\\/\\\\}"
secure_path="${secure_path//\"/\\\"}"
template="$(cat "${SOURCE_SCRIPT}")"
printf '%s\n' "${template//__SECURE_PDF_SCRIPT__/${secure_path}}" > "${temp}"
/usr/bin/osacompile -o "${temp}.scpt" "${temp}"
mv "${temp}.scpt" "${DEST_SCRIPT}"

echo "Installed Folder Action script:"
echo "${DEST_SCRIPT}"
if [[ $# -eq 2 ]]; then
  /usr/bin/osascript "${SCRIPT_DIR}/register_folder_action.applescript" "$2" "${DEST_SCRIPT}"
  exit 0
fi
echo
echo "Next step:"
echo "Open Finder, right-click the target folder, choose Folder Actions Setup,"
echo "and enable PDF自動権限付与.scpt for that folder."
