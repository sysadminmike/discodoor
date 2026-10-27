#!/bin/sh
#
# discodoor-allow.sh - look up one or more Syncthing device IDs on the global
# discovery servers and load their public IPs into a pf table or an
# nftables set.
#
# Usage: discodoor-allow.sh [-b pf|nft] [-t table] [-u lookup-url] [-c cert -K key] [-f file] [-d] [-n] [-k] [DEVICE-ID ...]
#
#   -f FILE    read device IDs from FILE, one per line; anything after a #
#              is a comment, and blank lines are skipped. Can be combined
#              with IDs on the command line.
#   -b BACKEND pf or nft (default: pf if pfctl is found, else nft)
#   -t TABLE   pf:  table name (default: ssh_ok)
#              nft: set as FAMILY:TABLE:SET, or just SET for inet:filter:SET
#                   (default: inet:filter:ssh_ok)
#   -u URL     lookup server (default: https://discovery-lookup.syncthing.net/v2/)
#   -c CERT    TLS client certificate (PEM) to present to the lookup server, for a
#              discodoor-server with --lookup-access listed/watchers (needs -K)
#   -K KEY     private key for CERT (PEM)
#   -d         debug: show URLs, responses and what would change
#   -n         dry run: show what would change, don't touch the firewall
#   -k         don't verify the lookup server's TLS certificate
#   -h         this help
#
# pf.conf needs something like:
#   table <ssh_ok> persist
#   pass in on $ext_if proto tcp from <ssh_ok> to port 22 keep state
#
# nftables needs something like:
#   table inet filter {
#     set ssh_ok { type ipv4_addr; }
#     chain input {
#       ...
#       ct state established,related accept
#       tcp dport 22 ip saddr @ssh_ok accept
#     }
#   }
#
# The nft backend is IPv4 only for now; IPv6 addresses are skipped.
#
# Run from root's crontab, e.g. every 5 minutes:
#   */5 * * * * /usr/local/sbin/discodoor-allow.sh AAAAAAA-BBBBBBB-...
#   */5 * * * * /usr/local/sbin/discodoor-allow.sh -f /usr/local/etc/discodoor/allowed-devices
#
# An -f file looks like:
#   # laptop and the backup server
#   AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH   # laptop
#   IIIIIII-JJJJJJJ-KKKKKKK-LLLLLLL-MMMMMMM-NNNNNNN-OOOOOOO-PPPPPPP   # backup server
#
# Needs: pfctl or nft, and curl or FreeBSD's fetch(1). No jq needed.
#
# Behaviour:
#   - all lookups succeed  -> table is REPLACED with the IPs found
#                             (old IPs drop out when a peer's IP changes)
#   - some lookups fail    -> found IPs are only ADDED (nothing removed, so
#                             a failed lookup never locks a peer out)
#   - nothing found at all -> table left alone, exit 1
#   - relay://, private, loopback, link-local and CGNAT addresses are ignored
#   - established connections survive table changes (pf keeps state;
#     nft needs the ct state rule above)

BACKEND=
TABLE=
LOOKUP=https://discovery-lookup.syncthing.net/v2/
DEBUG=0
DRYRUN=0
INSECURE=0
CERT=
KEY=
IDFILE=
TAG=discodoor

usage() {
	sed -n '3,/^$/s/^# \{0,1\}//p' "$0"
	exit "${1:-0}"
}

dbg() {
	if [ "$DEBUG" = 1 ]; then echo "[debug] $*" >&2; fi
}

# Log to syslog, and to stderr when run by hand or with -d. Dry runs are
# marked so they can't be mistaken for real changes in the log.
log() {
	msg="$*"
	[ "$DRYRUN" = 1 ] && msg="dry run: $msg"
	logger -t "$TAG" -- "$msg" 2>/dev/null
	if [ "$DEBUG" = 1 ] || [ -t 2 ]; then echo "$TAG: $msg" >&2; fi
}

get() {
	if command -v curl >/dev/null 2>&1; then
		if [ "$INSECURE" = 1 ]; then
			# shellcheck disable=SC2086 # CERT/KEY options deliberately split
			curl -sf --max-time 20 -k ${CERT:+--cert "$CERT" --key "$KEY"} "$1"
		else
			# shellcheck disable=SC2086 # CERT/KEY options deliberately split
			curl -sf --max-time 20 ${CERT:+--cert "$CERT" --key "$KEY"} "$1"
		fi
	elif command -v fetch >/dev/null 2>&1; then
		if [ "$INSECURE" = 1 ]; then
			# shellcheck disable=SC2086 # CERT/KEY options deliberately split
			fetch -q -T 20 --no-verify-peer ${CERT:+--cert="$CERT" --key="$KEY"} -o - "$1"
		else
			# shellcheck disable=SC2086 # CERT/KEY options deliberately split
			fetch -q -T 20 ${CERT:+--cert="$CERT" --key="$KEY"} -o - "$1"
		fi
	else
		log "need curl or fetch"
		exit 2
	fi
}

# Print the device IDs in a file, one per line. Anything after a # is a
# comment; blank lines and comment-only lines are skipped. Carriage returns
# are dropped, so a file edited on Windows still works.
read_ids() {
	file=$1
	[ -r "$file" ] || { log "can't read $file"; exit 2; }
	n=0
	tr -d '\r' < "$file" | while read -r id rest || [ -n "$id$rest" ]; do
		n=$((n + 1))
		case "$id" in
		*'#'*) id=${id%%#*}; rest= ;;
		esac
		rest=${rest%%#*}
		[ -n "$id" ] || continue
		case "$rest" in
		*[![:space:]]*) log "$file line $n: ignoring text after the ID; put notes after a #" ;;
		esac
		echo "$id"
	done
}

# Pull addresses out of the JSON, drop relays, strip scheme/port/brackets,
# drop non-public addresses.
extract_ips() {
	grep -oE '"[a-z0-9]+://[^"]*"' |
	tr -d '"' |
	grep -v '^relay://' |
	sed -E 's#^[a-z0-9]+://##; s#\?.*$##; s#/.*$##; s#:[0-9]+$##; s#^\[##; s#\]$##' |
	grep -Ev '^(0\.0\.0\.0|10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' |
	grep -Eiv '^(::|::1|fe80:|f[cd][0-9a-f]{2}:)' |
	grep -E '^[0-9a-fA-F:.]+$'
}

# ---- pf backend ------------------------------------------------------------
# A pf table holds IPv4 and IPv6, and -T add/replace create it if missing.

pf_init() {
	command -v pfctl >/dev/null 2>&1 || { log "pfctl not found"; exit 2; }
	[ -n "$TABLE" ] || TABLE=ssh_ok
	TARGET="table <$TABLE>"
}

pf_filter() {
	cat
}

pf_show() {
	pfctl -t "$TABLE" -T show 2>/dev/null | tr -d ' ' | sort -u
}

pf_add() {
	[ "$DRYRUN" = 1 ] && { echo "dry run: pfctl -t $TABLE -T add $*"; return; }
	pfctl -q -t "$TABLE" -T add "$@"
}

pf_replace() {
	[ "$DRYRUN" = 1 ] && { echo "dry run: pfctl -t $TABLE -T replace $*"; return; }
	pfctl -q -t "$TABLE" -T replace "$@"
}

# ---- nftables backend ------------------------------------------------------
# The set must already exist, with type ipv4_addr. IPv4 only for now.

nft_init() {
	command -v nft >/dev/null 2>&1 || { log "nft not found"; exit 2; }
	t=${TABLE:-ssh_ok}
	case "$t" in
	*:*:*)
		NFT_FAMILY=${t%%:*}
		t=${t#*:}
		NFT_TABLE=${t%%:*}
		NFT_SET=${t#*:}
		;;
	*:*)
		log "nft set must be FAMILY:TABLE:SET or SET, not $t"
		exit 2
		;;
	*)
		NFT_FAMILY=inet
		NFT_TABLE=filter
		NFT_SET=$t
		;;
	esac
	NFT="$NFT_FAMILY $NFT_TABLE $NFT_SET"
	TARGET="nft set $NFT"
	# shellcheck disable=SC2086 # NFT is "family table set": three words
	if ! nft list set $NFT >/dev/null 2>&1; then
		log "can't read $TARGET (does it exist? are you root?)"
		exit 2
	fi
}

nft_filter() {
	while read -r ip; do
		case "$ip" in
		*:*) dbg "skipping $ip: nft backend is IPv4 only" ;;
		*) echo "$ip" ;;
		esac
	done
}

# nft prints "elements = { a, b,\n c }"; take the first word of each element.
nft_show() {
	# shellcheck disable=SC2086 # NFT is "family table set": three words
	nft list set $NFT 2>/dev/null |
	sed -n '/elements = {/,/}/p' |
	sed 's/.*{//; s/}.*//' |
	tr ',' '\n' |
	sed 's/^[[:space:]]*//; s/[[:space:]].*//' |
	grep -E '^[0-9.]+$' |
	sort -u
}

nft_add() {
	list=$(echo "$*" | sed 's/ /, /g')
	[ "$DRYRUN" = 1 ] && { echo "dry run: nft add element $NFT { $list }"; return; }
	# shellcheck disable=SC2086 # NFT is "family table set": three words
	nft add element $NFT "{ $list }"
}

# flush + add in one nft -f run is a single transaction, like pf's -T replace.
nft_replace() {
	list=$(echo "$*" | sed 's/ /, /g')
	script="flush set $NFT
add element $NFT { $list }"
	[ "$DRYRUN" = 1 ] && { printf 'dry run: nft -f - <<EOF\n%s\nEOF\n' "$script"; return; }
	printf '%s\n' "$script" | nft -f -
}

# ---- main ------------------------------------------------------------------

while getopts "b:t:u:c:K:f:dnkh" opt; do
	case "$opt" in
	b) BACKEND=$OPTARG ;;
	t) TABLE=$OPTARG ;;
	u) LOOKUP=$OPTARG ;;
	c) CERT=$OPTARG ;;
	K) KEY=$OPTARG ;;
	f) IDFILE=$OPTARG ;;
	d) DEBUG=1 ;;
	n) DRYRUN=1 ;;
	k) INSECURE=1 ;;
	h) usage 0 ;;
	*) usage 1 ;;
	esac
done
shift $((OPTIND - 1))
if [ -n "$IDFILE" ]; then
	ids=$(read_ids "$IDFILE") || exit 2
	# shellcheck disable=SC2086 # one ID per line; splitting intended
	set -- "$@" $ids
	if [ $# -eq 0 ]; then
		log "no device IDs in $IDFILE; nothing changed"
		exit 1
	fi
fi
[ $# -ge 1 ] || usage 1
if [ -n "$CERT$KEY" ] && { [ -z "$CERT" ] || [ -z "$KEY" ]; }; then
	echo "$TAG: -c and -K go together" >&2
	exit 1
fi

if [ -z "$BACKEND" ]; then
	if command -v pfctl >/dev/null 2>&1; then
		BACKEND=pf
	elif command -v nft >/dev/null 2>&1; then
		BACKEND=nft
	else
		log "need pfctl or nft"
		exit 2
	fi
fi
case "$BACKEND" in
pf) pf_init ;;
nft) nft_init ;;
*) usage 1 ;;
esac
dbg "backend $BACKEND, $TARGET"

found=""
failed=0
for id in "$@"; do
	url="${LOOKUP}?device=${id}"
	dbg "lookup $url"
	if ! body=$(get "$url"); then
		log "lookup failed for $id (offline, not announced yet, or network/TLS error)"
		failed=1
		continue
	fi
	dbg "response: $body"
	ips=$(printf '%s\n' "$body" | extract_ips | "${BACKEND}_filter")
	if [ -z "$ips" ]; then
		log "no usable addresses for $id"
		failed=1
		continue
	fi
	# shellcheck disable=SC2116,SC2086 # echo flattens a multi-line list for the log
	dbg "$id -> $(echo $ips)"
	found="$found $ips"
done

# shellcheck disable=SC2086 # found holds whitespace-separated IPs; splitting intended
found=$(printf '%s\n' $found | sort -u)
if [ -z "$found" ]; then
	log "nothing found; $TARGET left unchanged"
	exit 1
fi

current=$("${BACKEND}_show")
# shellcheck disable=SC2116,SC2086 # echo flattens a multi-line list for the log
dbg "$TARGET now: $(echo $current)"
# shellcheck disable=SC2116,SC2086 # echo flattens a multi-line list for the log
dbg "wanted: $(echo $found)"

if [ "$failed" = 1 ]; then
	# shellcheck disable=SC2086 # found holds whitespace-separated IPs; splitting intended
	new=$(printf '%s\n' $found | while read -r ip; do
		printf '%s\n' "$current" | grep -qxF "$ip" || echo "$ip"
	done)
	if [ -z "$new" ]; then
		dbg "some lookups failed; nothing new to add"
		exit 0
	fi
	# shellcheck disable=SC2116,SC2086 # echo flattens a multi-line list for the log
	log "some lookups failed; adding only: $(echo $new)"
	# shellcheck disable=SC2086 # the IP list is passed as separate arguments
	"${BACKEND}_add" $new
else
	if [ "$current" = "$found" ]; then
		dbg "no change"
		exit 0
	fi
	# shellcheck disable=SC2116,SC2086 # echo flattens a multi-line list for the log
	log "$TARGET: [$(echo $current)] -> [$(echo $found)]"
	# shellcheck disable=SC2086 # the IP list is passed as separate arguments
	"${BACKEND}_replace" $found
fi
