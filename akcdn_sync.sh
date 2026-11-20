#!/bin/sh
# ==============================================================================
# AKCDN Auto Dynamic Whitelist Sync for OpenWrt
# Periodically checks local domestic public IPv4 (via direct routes)
# and updates Akile CDN forwarding rules (15431, 15434, 15437, etc.)
# ==============================================================================

set -eu

API_TOKEN="${AKCDN_TOKEN:-ak_YOUR_API_TOKEN_HERE}"
API_BASE="https://cdnapi.akile.ai/api/open"
CACHE_FILE="/tmp/akcdn_last_ip"
LOG_TAG="akcdn-sync"

log() {
    logger -t "$LOG_TAG" "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Fetch direct domestic public IPv4
get_public_ip() {
    local ip=""
    # 1. ip.3322.net (domestic CN, hits direct route)
    ip=$(curl -4 -s -m 4 http://ip.3322.net 2>/dev/null | tr -d '\r\n ' || true)
    if [ -n "$ip" ] && echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "$ip"
        return 0
    fi

    # 2. 4.ipw.cn (domestic CN)
    ip=$(curl -4 -s -m 4 https://4.ipw.cn 2>/dev/null | tr -d '\r\n ' || true)
    if [ -n "$ip" ] && echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "$ip"
        return 0
    fi

    # 3. ddns.oray.com
    ip=$(curl -4 -s -m 4 http://ddns.oray.com/checkip 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi

    return 1
}

CURRENT_IP=$(get_public_ip || true)
if [ -z "$CURRENT_IP" ]; then
    log "ERROR: Failed to detect current public IPv4 address"
    exit 1
fi

LAST_IP=""
if [ -f "$CACHE_FILE" ]; then
    LAST_IP=$(cat "$CACHE_FILE" 2>/dev/null || true)
fi

FORCE="${1:-}"
if [ "$FORCE" != "--force" ] && [ "$CURRENT_IP" = "$LAST_IP" ]; then
    # IP has not changed
    exit 0
fi

log "Detected IP change: '${LAST_IP}' -> '${CURRENT_IP}'. Syncing Akile CDN rules..."

# Fetch all rules from Akile API
RULES_RESP=$(curl -s -m 10 -H "X-API-Key: ${API_TOKEN}" "${API_BASE}/rules" 2>/dev/null || true)
if [ -z "$RULES_RESP" ] || ! echo "$RULES_RESP" | grep -q '"data"'; then
    log "ERROR: Failed to fetch rules from Akile API"
    exit 1
fi

# Extract rule IDs using sed/grep (posix compliant, no jq required)
RULE_IDS=$(echo "$RULES_RESP" | grep -Eo '"id":[0-9]+' | cut -d: -f2)

SUCCESS_COUNT=0
FAIL_COUNT=0

for RID in $RULE_IDS; do
    UPDATE_RESP=$(curl -s -m 8 -X PUT \
        -H "X-API-Key: ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"entry_whitelist\":\"${CURRENT_IP}\"}" \
        "${API_BASE}/rules/${RID}/entry-whitelist" 2>/dev/null || true)

    if echo "$UPDATE_RESP" | grep -q "${CURRENT_IP}"; then
        log "Rule #${RID} whitelist updated to ${CURRENT_IP}/32"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        log "WARNING: Rule #${RID} update failed: ${UPDATE_RESP}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

if [ "$SUCCESS_COUNT" -gt 0 ]; then
    echo "$CURRENT_IP" > "$CACHE_FILE"
    log "Sync finished: ${SUCCESS_COUNT} rules updated, ${FAIL_COUNT} failed. Current IP: ${CURRENT_IP}"
else
    log "ERROR: All rule updates failed"
    exit 1
fi
