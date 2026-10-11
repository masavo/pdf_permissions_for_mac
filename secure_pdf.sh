#!/usr/bin/env bash
set +x +v
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/runtime.sh" || exit 1

resolve_qpdf() {
  QPDF_BIN="$(find_tool qpdf "${QPDF_BIN}")" && return 0
  log "ERROR" "qpdf is unavailable. Install qpdf or set QPDF_BIN to its absolute path."
  return 1
}

log() {
  local level="$1"
  local message="$2"
  message="${message//$'\n'/\\n}"
  message="${message//$'\r'/\\r}"
  [[ ! -L "${LOG_FILE}" ]] || return 1
  mkdir -p "$(dirname "${LOG_FILE}")" || return 1
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${message}" >> "${LOG_FILE}"
}

usage() {
  cat <<'USAGE'
Usage:
  secure_pdf.sh /path/to/file.pdf [...]
  secure_pdf.sh --check-config

Environment/config (.settings, or .env with the dotenv backend):
  SECRET_BACKEND              envchain, dotenv, environment, or auto (legacy).
  ENVCHAIN_NAMESPACE          Keychain namespace (default pdf-permissions).
  TARGET_PREFIX               Process only PDF basenames that start with this prefix.
  OWNER_PASSWORD              Required PDF owner password.
  USER_PASSWORD               Optional PDF open password. Empty means no open password.
  PERMISSION_POLICY           print_copy_annotate, strict, or custom.
  QPDF_PERMISSION_ARGS        Required only when PERMISSION_POLICY=custom.
  QPDF_BIN                    Optional absolute path to qpdf (Homebrew auto-detected).
  LOG_FILE                    Log output path.

Default policy: print_copy_annotate
  Allows printing, text/graphics copying, and annotations/signatures.
  Disallows page assembly, existing form filling, and other edits.
USAGE
}

is_pdf_path() {
  local path="$1"
  case "${path}" in
    *.[pP][dD][fF]) return 0 ;;
    *) return 1 ;;
  esac
}

basename_matches_prefix() {
  local path="$1"
  local name
  name="$(basename "${path}")"

  if [[ -z "${TARGET_PREFIX}" ]]; then
    return 0
  fi

  [[ "${name}" == "${TARGET_PREFIX}"* ]]
}

wait_until_stable() {
  local path="$1"
  local previous_size="-1"
  local stable_count="0"
  local started="${SECONDS}"

  if [[ ! "${STABILITY_CHECKS}" =~ ^[1-9][0-9]*$ ]] ||
     [[ ! "${STABILITY_INTERVAL_SECONDS}" =~ ^([1-9][0-9]*([.][0-9]+)?|0[.][0-9]*[1-9][0-9]*)$ ]] ||
     [[ ! "${STABILITY_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    log "ERROR" "Invalid stability check configuration"
    return 1
  fi

  while (( stable_count < STABILITY_CHECKS )); do
    if (( SECONDS - started >= STABILITY_TIMEOUT_SECONDS )); then
      log "ERROR" "Timed out waiting for file stability: ${path}"
      return 1
    fi
    if [[ ! -f "${path}" ]]; then
      log "ERROR" "File disappeared while waiting: ${path}"
      return 1
    fi

    local current_size
    if ! current_size="$(stat -f '%z' "${path}" 2>/dev/null || stat -c '%s' "${path}" 2>/dev/null)"; then
      log "ERROR" "Failed to read file size: ${path}"
      return 1
    fi

    if [[ "${current_size}" == "${previous_size}" ]]; then
      stable_count=$((stable_count + 1))
    else
      stable_count="0"
      previous_size="${current_size}"
    fi

    sleep "${STABILITY_INTERVAL_SECONDS}" || return 1
  done
}

build_permission_args() {
  case "${PERMISSION_POLICY}" in
    print_copy_annotate)
      PERMISSION_ARGS=(
        "--print=full"
        "--extract=y"
        "--assemble=n"
        "--annotate=y"
        "--form=n"
        "--modify-other=n"
        "--accessibility=y"
      )
      ;;
    strict)
      PERMISSION_ARGS=(
        "--print=none"
        "--extract=n"
        "--assemble=n"
        "--annotate=n"
        "--form=n"
        "--modify-other=n"
        "--accessibility=y"
      )
      ;;
    custom)
      if [[ -z "${QPDF_PERMISSION_ARGS:-}" || "${QPDF_PERMISSION_ARGS}" == *$'\n'* || "${QPDF_PERMISSION_ARGS}" == *$'\r'* ]]; then
        log "ERROR" "PERMISSION_POLICY=custom requires QPDF_PERMISSION_ARGS"
        return 1
      fi
      # QPDF_PERMISSION_ARGS is intentionally split into qpdf flags.
      # Keep passwords in OWNER_PASSWORD/USER_PASSWORD, not in this value.
      read -r -a PERMISSION_ARGS <<< "${QPDF_PERMISSION_ARGS}"
      local argument
      for argument in "${PERMISSION_ARGS[@]}"; do
        case "${argument}" in
          --print=full|--print=low|--print=none|--extract=[yn]|--assemble=[yn]|--annotate=[yn]|--form=[yn]|--modify-other=[yn]|--accessibility=[yn]) ;;
          *) log "ERROR" "Unsupported custom permission argument"; return 1 ;;
        esac
      done
      ;;
    *)
      log "ERROR" "Unknown PERMISSION_POLICY: ${PERMISSION_POLICY}"
      return 1
      ;;
  esac
}

secure_pdf() (
  local input="$1"
  [[ "${input}" == /* ]] || input="${PWD}/${input}"

  if ! is_pdf_path "${input}"; then
    log "INFO" "Skipped non-PDF: ${input}"
    return 0
  fi

  if ! basename_matches_prefix "${input}"; then
    log "INFO" "Skipped prefix mismatch: ${input}"
    return 0
  fi

  if [[ ! -f "${input}" || -L "${input}" ]]; then
    log "ERROR" "File not found: ${input}"
    return 1
  fi

  if [[ -z "${OWNER_PASSWORD}" || "${OWNER_PASSWORD}" == change-this-owner-password || "${OWNER_PASSWORD}" == "${USER_PASSWORD}" ]]; then
    log "ERROR" "A non-placeholder owner password, different from the user password, is required"
    return 1
  fi

  log "INFO" "Processing: ${input}" || return 1

  # qpdf's @- input represents each argument on one line. Reject line breaks
  # rather than allowing a password/path to become additional command options.
  if [[ "${OWNER_PASSWORD}${USER_PASSWORD}${input}" == *$'\n'* ]] ||
     [[ "${OWNER_PASSWORD}${USER_PASSWORD}${input}" == *$'\r'* ]]; then
    log "ERROR" "Passwords and PDF paths must not contain line breaks"
    return 1
  fi

  resolve_qpdf || return 1

  build_permission_args || return 1
  wait_until_stable "${input}" || return 1

  local dir
  local name
  local temp
  local lock original_digest
  dir="$(cd "$(dirname "${input}")" && pwd -P)" || return 1
  name="$(basename "${input}")"
  input="${dir}/${name}"
  lock="${dir}/.secure-pdf-$(printf '%s' "${input}" | /usr/bin/shasum -a 256 | cut -d ' ' -f 1).lock"
  if ! mkdir "${lock}" 2>/dev/null; then
    log "ERROR" "Another process or a stale lock blocks this PDF: ${input}"
    return 1
  fi
  temp=""
  trap '[[ -z "${temp}" ]] || rm -f "${temp}"; rmdir "${lock}" 2>/dev/null || true' EXIT
  trap 'exit 1' HUP INT TERM
  original_digest="$(/usr/bin/shasum -a 256 "${input}")" || return 1
  temp="$(mktemp "${dir}/.secure-pdf.XXXXXX")" || return 1

  local status
  # Keep passwords out of the process argument list and out of disk files.
  if printf '%s\n' --encrypt "--user-password=${USER_PASSWORD}" \
    "--owner-password=${OWNER_PASSWORD}" --bits=256 "${PERMISSION_ARGS[@]}" \
    -- "${input}" "${temp}" | "${QPDF_BIN}" @- 2>> "${LOG_FILE}"; then
    if [[ -L "${input}" ]] || [[ "$(/usr/bin/shasum -a 256 "${input}")" != "${original_digest}" ]]; then
      log "ERROR" "Input changed during processing; output discarded: ${input}"
      return 1
    fi
    if mv "${temp}" "${input}"; then
      log "INFO" "Secured and replaced: ${input}"
      return 0
    fi

    log "ERROR" "Failed to replace original after qpdf success: ${input}"
    rm -f "${temp}"
    return 1
  else
    status="$?"
  fi

  rm -f "${temp}"
  log "ERROR" "qpdf failed with status ${status}: ${input}"
  return "${status}"
)

main() {
  if [[ "$#" -eq 0 ]]; then
    usage
    exit 2
  fi
  if [[ "$1" == --help || "$1" == -h ]]; then
    usage
    exit 0
  fi
  load_runtime "$@" || exit 1
  if [[ "$1" == --check-config ]]; then
    if [[ -z "${OWNER_PASSWORD}" || "${OWNER_PASSWORD}" == change-this-owner-password || "${OWNER_PASSWORD}" == "${USER_PASSWORD}" ]]; then
      echo 'Set a non-placeholder owner password different from the user password.' >&2
      exit 1
    fi
    if [[ "${OWNER_PASSWORD}${USER_PASSWORD}" == *$'\n'* || "${OWNER_PASSWORD}${USER_PASSWORD}" == *$'\r'* ]]; then
      echo 'Passwords must not contain line breaks.' >&2
      exit 1
    fi
    resolve_qpdf && build_permission_args || exit 1
    echo "Configuration OK (${SECRET_BACKEND})"
    exit 0
  fi

  local status="0"
  local file
  for file in "$@"; do
    secure_pdf "${file}" || status="1"
  done

  exit "${status}"
}

main "$@"
