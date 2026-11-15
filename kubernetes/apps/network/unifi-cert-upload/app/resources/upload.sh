#!/usr/bin/env bash
set -euo pipefail

base_url="https://${UNIFI_HOST:?}"
cert_dir="${CERT_DIR:-/certs}"
csrf_token=""

info() {
  echo "[INFO ] $*" >&2
}

fatal() {
  echo "[FATAL] $*" >&2
  exit 1
}

request() {
  local method="$1" path="$2"
  shift 2

  curl --insecure --fail --silent --show-error \
    --connect-timeout 10 --max-time 60 \
    --cookie "${work_dir}/cookies" \
    --cookie-jar "${work_dir}/cookies" \
    -H "Content-Type: application/json" \
    -H "x-csrf-token: ${csrf_token}" \
    -X "${method}" "${base_url}${path}" "$@"
}

login() {
  info "Logging into UniFi"
  jq -n '{username: env.UNIFI_USERNAME, password: env.UNIFI_PASSWORD}' |
    request POST /api/auth/login --data-binary @- \
      --dump-header "${work_dir}/headers" --output /dev/null ||
    fatal "Failed to log in"

  csrf_token="$(awk '
    tolower($1) == "x-csrf-token:" {
      gsub(/\r/, "", $2)
      print $2
    }
  ' "${work_dir}/headers")"
  [[ -n "${csrf_token}" ]] || fatal "Login response has no CSRF token"
}

find_certificate() {
  local fingerprint="$1" certificates
  certificates="$(request GET /api/userCertificates)" ||
    fatal "Failed to list certificates"
  jq -e 'type == "array"' <<< "${certificates}" >/dev/null ||
    fatal "Unexpected certificate list response"

  jq -c --arg fingerprint "${fingerprint}" '
    [.[] | select(
      (.fingerprint | ascii_upcase) == ($fingerprint | ascii_upcase)
    )][0] // null
  ' <<< "${certificates}"
}

upload_certificate() {
  info "Uploading new certificate"
  jq -n \
    --arg name "le-$(date +%Y%m%d%H%M%S)" \
    --rawfile cert "${cert_dir}/tls.crt" \
    --rawfile key "${cert_dir}/tls.key" \
    '{name: $name, cert: $cert, key: $key}' |
    request POST /api/userCertificates --data-binary @- ||
    fatal "Failed to upload certificate"
}

certificate_id() {
  jq -er '
    .id
    | select(type == "string")
    | select(test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"))
  ' || fatal "Certificate response has no valid ID"
}

is_active() {
  jq -e '.active == true' >/dev/null
}

activate_certificate() {
  local id="$1" fingerprint="$2" certificate

  info "Activating certificate"
  request PUT "/api/userCertificates/${id}/status" \
    --data-binary '{"active":true}' >/dev/null ||
    fatal "Failed to activate certificate"

  certificate="$(find_certificate "${fingerprint}")"
  jq -e --arg id "${id}" '.id == $id and .active == true' \
    <<< "${certificate}" >/dev/null ||
    fatal "Certificate is not active"
}

main() {
  local fingerprint certificate id

  info "Installing dependencies..."
  dnf install -y jq openssl

  umask 077
  work_dir="$(mktemp -d)"
  trap 'rm -rf "${work_dir}"' EXIT

  # UniFi uses the SHA-1 fingerprint of the leaf certificate.
  fingerprint="$(openssl x509 -in "${cert_dir}/tls.crt" -noout -fingerprint -sha1)"
  fingerprint="${fingerprint#*=}"
  [[ -n "${fingerprint}" ]] || fatal "Missing certificate fingerprint"

  login
  certificate="$(find_certificate "${fingerprint}")"
  if is_active <<< "${certificate}"; then
    info "Certificate is already active; nothing to do"
    return
  fi

  if [[ "${certificate}" == "null" ]]; then
    certificate="$(upload_certificate)"
  else
    info "Reusing existing certificate"
  fi

  id="$(certificate_id <<< "${certificate}")"
  activate_certificate "${id}" "${fingerprint}"
  info "Complete"
}

main
