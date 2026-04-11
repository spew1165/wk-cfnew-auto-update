#!/bin/bash

set -e

KV_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WRANGLER_TOML="$PROJECT_DIR/wrangler.toml"
LOG_FILE="$SCRIPT_DIR/step-kv.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

error() {
    log "ERROR: $1"
    echo "ERROR: $1" >&2
    exit 1
}

generate_random_suffix() {
    local chars="0123456789abcdefghijklmnopqrstuvwxyz"
    local result="-"
    for i in {1..4}; do
        result="${result}${chars:$(($RANDOM % ${#chars})):1}"
    done
    echo "$result"
}

check_kv_exists() {
    local name="$1"
    npx wrangler kv namespace list 2>/dev/null | grep -q "\"title\": \"$name\"" && return 0 || return 1
}

generate_unique_name() {
    local name="$1"
    local new_name="$name"

    while check_kv_exists "$new_name"; do
        local suffix=$(generate_random_suffix)
        new_name="${name}${suffix}"
        log "KV '$name' exists, trying: $new_name"
    done

    echo "$new_name"
}

create_kv() {
    local name="$1"
    log "Creating KV: $name"

    local output=$(npx wrangler kv namespace create "$name" --binding "C" --update-config 2>&1)

    if echo "$output" | grep -q "Error\|error\|ERROR"; then
        error "KV creation failed: $output"
    fi

    local kv_id=$(echo "$output" | grep -oP "id = \"\K[^\"]+")

    if [ -z "$kv_id" ]; then
        error "Cannot extract KV ID from output"
    fi

    echo "$kv_id"
}

update_wrangler_toml() {
    local kv_id="$1"

    log "Updating wrangler.toml with KV ID: $kv_id"

    if [ ! -f "$WRANGLER_TOML" ]; then
        error "wrangler.toml not found"
    fi

    local content=$(cat "$WRANGLER_TOML")

    local new_content="${content}

[[kv_namespaces]]
binding = \"C\"
id = \"${kv_id}\"
"

    echo "$new_content" > "$WRANGLER_TOML"
    log "wrangler.toml updated"
}

main() {
    if [ -z "$KV_NAME" ]; then
        echo "Usage: $0 <KVName>"
        echo "Example: $0 my-kv"
        exit 1
    fi

    log "========== Starting KV creation =========="
    log "Input: $KV_NAME"

    cd "$PROJECT_DIR"

    local final_name=$(generate_unique_name "$KV_NAME")

    if [ "$final_name" != "$KV_NAME" ]; then
        log "Final name: $final_name"
    fi

    local kv_id=$(create_kv "$final_name")
    log "KV ID: $kv_id"

    update_wrangler_toml "$kv_id"

    log "========== Done =========="
    echo ""
    echo "SUCCESS!"
    echo "  Name: $final_name"
    echo "  ID: $kv_id"
    echo "  wrangler.toml: Updated"
    echo ""
    echo "Next: npm run deploy"
}

main "$@"
