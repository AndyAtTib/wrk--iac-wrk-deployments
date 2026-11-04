#!/bin/bash

function sendecs() {
  local logpath="$1"; shift;
  local username="$1"; shift;
  local password="$1"; shift;
  local url_host="$1"; shift;
  local port="$1"; shift;

  [[ $logpath == "-" ]] && logpath="/tmp"
  local log="$logpath/sendecs-${host}"

  local url_resname="mon"
  local qry_id="umg-dwd-drtmon01"
  local dt=$(date -u -Ins)
  local qry_version="$(echo $dt | sed 's|[T+:,\-]||g' | sed -E 's|^([0-9]{17}).+|\1|')"
  local qry_source="monvm"
  # for uuidgen, if which uuidgen fails: sudo apt-get update && sudo apt install -y uuid-runtime
  local qry_messageid="uuidgen-failed-or-missing"; uuidgen && qry_messageid=$(uuidgen || echo "nf");

  local payload=$(cat << EOF
<?xml version="1.0" encoding="UTF-8"?>
<test source="${qry_source}" messageid="${qry_messageid}" qry_version="${qry_version}" />
EOF
)

  echo "username:='$username'; url_host='${url_host}${port:+:$port}'; qry_version='$qry_version'; qry_messageid='$qry_messageid'"

  local url_qry="identifier=${qry_id:-testid}&version=${qry_version}&source=${qry_source}&messageid=${qry_messageid}"
  local url="https://${url_host}${port:+:$port}/resources/${url_resname}?${url_qry}"
  local is_verbose="v"
  curl --connect-timeout 10 -m 20 --no-progress-meter \
    ${is_verbose:+-v} \
    -o "$log.resp.txt" \
    -H "Content-Type: application/xml" \
    -d "$payload" \
    -u "${username}:${password}" \
    "$url" 2>&1 | tee "${log}.curl.log"

  #local dt="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo -e "$dt: executed http get to ${url}:  username:='$username'; url_host='${url_host}${port:+:$port}'; qry_version='$qry_version'; qry_messageid='$qry_messageid'" > "$log.execs.log"
}

sendecs "/.data/ecs-tests/" "$1" "$2" "$3" "$4" "$5"
