#!/usr/bin/env bash

# date_utils.sh - Cross-platform date utility functions
# Provides consistent date formatting across GNU (Linux) and BSD (macOS)

# Get current timestamp in ISO 8601 format
get_iso_timestamp() {
    local result
    if result=$(date -u -Iseconds 2>/dev/null) && [[ -n "$result" ]]; then
        echo "$result"
        return
    fi
    date -u +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\(..\)$/:\1/'
}

# Get current Unix epoch time in seconds
get_epoch_seconds() {
    date +%s
}

# Convert ISO 8601 timestamp to Unix epoch seconds
parse_iso_to_epoch() {
    local iso_timestamp=$1

    if [[ -z "$iso_timestamp" || "$iso_timestamp" == "null" ]]; then
        date +%s
        return
    fi

    local result
    # Try GNU date
    if result=$(date -d "$iso_timestamp" +%s 2>/dev/null) && [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
        return
    fi

    # Try BSD date
    local tz_fixed
    tz_fixed=$(echo "$iso_timestamp" | sed -E 's/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
    if result=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$tz_fixed" +%s 2>/dev/null) && [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
        return
    fi

    # Fallback
    date +%s
}

export -f get_iso_timestamp
export -f get_epoch_seconds
export -f parse_iso_to_epoch
