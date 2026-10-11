#!/usr/bin/env bash
# Sourced by secure_pdf.sh and setup.sh. Configuration files are trusted shell code.

find_tool() {
  local name="$1" explicit="${2:-}" candidate
  if [[ -n "${explicit}" ]]; then
    [[ "${explicit}" == /* && -x "${explicit}" ]] || return 1
    printf '%s\n' "${explicit}"
    return 0
  fi
  candidate="$(command -v "${name}" 2>/dev/null || true)"
  if [[ -n "${candidate}" && "${candidate}" == /* && -x "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  for candidate in "/opt/homebrew/bin/${name}" "/usr/local/bin/${name}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

load_settings() {
  local settings="${PDF_CONFIG_FILE:-${SCRIPT_DIR}/.settings}"
  if [[ -f "${settings}" ]]; then
    source "${settings}" || return 1
  fi
}

load_runtime() {
  local backend_override="${SECRET_BACKEND:-}"
  load_settings || return 1
  [[ -z "${backend_override}" ]] || SECRET_BACKEND="${backend_override}"
  : "${SECRET_BACKEND:=auto}"
  if [[ "${SECRET_BACKEND}" == auto ]]; then
    if [[ -n "${OWNER_PASSWORD:-}" || ! -f "${SCRIPT_DIR}/.env" ]]; then
      SECRET_BACKEND=environment
    else
      SECRET_BACKEND=dotenv
    fi
  fi
  case "${SECRET_BACKEND}" in
    environment) ;;
    dotenv)
      if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
        echo 'Missing .env. Run setup.sh --backend dotenv.' >&2
        return 1
      fi
      source "${SCRIPT_DIR}/.env" || return 1
      # setup-generated non-secret options take precedence over legacy .env options.
      load_settings || return 1
      SECRET_BACKEND=dotenv
      ;;
    envchain)
      : "${ENVCHAIN_NAMESPACE:=pdf-permissions}"
      if [[ ! "${ENVCHAIN_NAMESPACE}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo 'Invalid envchain namespace.' >&2
        return 1
      fi
      if [[ "${PDF_ENVCHAIN_ACTIVE:-}" != "${ENVCHAIN_NAMESPACE}" ]]; then
        local executable
        executable="$(find_tool envchain "${ENVCHAIN_BIN:-}")" || {
          echo 'envchain is unavailable. Install it with: brew install envchain' >&2
          return 1
        }
        # No .env fallback and no inherited passwords if the namespace is empty.
        unset OWNER_PASSWORD USER_PASSWORD
        export PDF_ENVCHAIN_ACTIVE="${ENVCHAIN_NAMESPACE}"
        exec "${executable}" "${ENVCHAIN_NAMESPACE}" /bin/bash "${SCRIPT_DIR}/secure_pdf.sh" "$@"
      fi
      ;;
    *) echo 'Unknown SECRET_BACKEND.' >&2; return 1 ;;
  esac
  : "${TARGET_PREFIX:=}"
  : "${OWNER_PASSWORD:=}"
  : "${USER_PASSWORD:=}"
  : "${PERMISSION_POLICY:=print_copy_annotate}"
  : "${QPDF_BIN:=}"
  : "${LOG_FILE:=${SCRIPT_DIR}/secure_pdf.log}"
  : "${STABILITY_CHECKS:=3}"
  : "${STABILITY_INTERVAL_SECONDS:=1}"
  : "${STABILITY_TIMEOUT_SECONDS:=120}"
  # envchain exports these. qpdf and utility subprocesses do not need them.
  export -n OWNER_PASSWORD USER_PASSWORD
}
