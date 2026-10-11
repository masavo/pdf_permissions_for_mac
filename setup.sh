#!/usr/bin/env bash
set +x +v
set -eu
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/runtime.sh"

usage() {
  cat <<'HELP'
Usage: ./setup.sh --folder /absolute/path/to/folder [options]
  --backend envchain|dotenv   Secret storage (default: envchain)
  --namespace NAME           envchain namespace (default: pdf-permissions)
  --prefix TEXT              PDF filename prefix (default: all PDFs in that folder)
  --install-deps             Install missing dependencies with Homebrew
  --skip-secrets             Reuse existing secrets without prompting
  --no-register              Configure and install; do not enable Folder Actions
  --help                    Show this help

Without --skip-secrets, envchain prompts for passwords with input echo disabled.
Existing .env files are never overwritten. Only new folder additions are processed.
HELP
}

backend=envchain
namespace=pdf-permissions
prefix=""
folder=""
install_deps=0
skip_secrets=0
register=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend|--namespace|--prefix|--folder)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      case "$1" in
        --backend) backend="$2" ;;
        --namespace) namespace="$2" ;;
        --prefix) prefix="$2" ;;
        --folder) folder="$2" ;;
      esac
      shift 2 ;;
    --install-deps) install_deps=1; shift ;;
    --skip-secrets) skip_secrets=1; shift ;;
    --no-register) register=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [[ -z "${folder}" && -t 0 ]]; then
  read -r -p 'Folder to watch (existing absolute path): ' folder
fi
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS is required.' >&2; exit 1; }
[[ "${backend}" == envchain || "${backend}" == dotenv ]] || { echo 'Invalid backend.' >&2; exit 2; }
[[ "${namespace}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { echo 'Invalid namespace.' >&2; exit 2; }
[[ "${prefix}" != *$'\n'* && "${prefix}" != *$'\r'* && "${prefix}" != */* ]] || { echo 'Invalid filename prefix.' >&2; exit 2; }
[[ "${folder}" == /* && -d "${folder}" ]] || { echo 'Specify an existing absolute folder path with --folder.' >&2; exit 2; }
folder="$(cd "${folder}" && pwd -P)"

required_tools=(qpdf)
[[ "${backend}" != envchain ]] || required_tools+=(envchain)
for tool in "${required_tools[@]}"; do
  if ! find_tool "${tool}" >/dev/null; then
    if [[ "${install_deps}" == 1 ]]; then
      brew_bin="$(find_tool brew)" || { echo 'Install Homebrew first: https://brew.sh' >&2; exit 1; }
      "${brew_bin}" install "${tool}"
    else
      echo "Missing ${tool}. Use --install-deps or run: brew install ${tool}" >&2
      exit 1
    fi
  fi
done
qpdf_bin="$(find_tool qpdf)"
version="$("${qpdf_bin}" --version)"
if [[ "${version}" =~ qpdf\ version\ ([0-9]+)[.]([0-9]+) ]]; then
  major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"
  (( major > 11 || (major == 11 && minor >= 7) )) || { echo 'qpdf 11.7 or later is required.' >&2; exit 1; }
else
  echo 'Cannot determine qpdf version.' >&2; exit 1
fi

if [[ "${backend}" == envchain ]]; then
  envchain_bin="$(find_tool envchain)"
  if [[ "${skip_secrets}" == 0 ]]; then
    [[ -t 0 ]] || { echo 'Run setup in a terminal to enter passwords, or use --skip-secrets.' >&2; exit 1; }
    echo 'Enter the owner password, then the optional open password (empty means no open password).'
    "${envchain_bin}" --set --noecho "${namespace}" OWNER_PASSWORD USER_PASSWORD
  fi
elif [[ ! -e "${SCRIPT_DIR}/.env" ]]; then
  [[ "${skip_secrets}" == 0 ]] || { echo 'No existing .env to reuse.' >&2; exit 1; }
  [[ -t 0 ]] || { echo 'Run setup in a terminal to enter passwords.' >&2; exit 1; }
  read -r -s -p 'Owner password: ' owner; printf '\n'
  read -r -s -p 'Open password (empty allowed): ' user; printf '\n'
  [[ -n "${owner}" && "${owner}" != "${user}" ]] || { echo 'Owner password is required and must differ from the open password.' >&2; exit 1; }
  # noclobber prevents replacing a file created concurrently.
  (set -o noclobber; printf 'OWNER_PASSWORD=%q\nUSER_PASSWORD=%q\n' "${owner}" "${user}" > "${SCRIPT_DIR}/.env")
  unset owner user
else
  [[ ! -L "${SCRIPT_DIR}/.env" ]] || { echo 'Refusing a symlink .env.' >&2; exit 1; }
  chmod 600 "${SCRIPT_DIR}/.env"
fi

settings="$(mktemp "${SCRIPT_DIR}/.settings.XXXXXX.tmp")"
trap 'rm -f "${settings}"' EXIT
{
  printf 'SECRET_BACKEND=%q\nENVCHAIN_NAMESPACE=%q\nTARGET_PREFIX=%q\n' "${backend}" "${namespace}" "${prefix}"
  printf 'PERMISSION_POLICY=print_copy_annotate\nQPDF_BIN=%q\n' "${qpdf_bin}"
  [[ "${backend}" != envchain ]] || printf 'ENVCHAIN_BIN=%q\n' "${envchain_bin}"
} > "${settings}"
SECRET_BACKEND="${backend}" PDF_CONFIG_FILE="${settings}" /bin/bash "${SCRIPT_DIR}/secure_pdf.sh" --check-config
[[ ! -L "${SCRIPT_DIR}/.settings" ]] || { echo 'Refusing a symlink .settings.' >&2; exit 1; }
mv "${settings}" "${SCRIPT_DIR}/.settings"
if [[ "${register}" == 1 ]]; then
  /bin/bash "${SCRIPT_DIR}/install_folder_action.sh" --attach "${folder}"
else
  /bin/bash "${SCRIPT_DIR}/install_folder_action.sh"
fi
echo 'Setup complete. Existing PDFs were not processed.'
