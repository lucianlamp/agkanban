#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
setup-codex-sandbox.sh — add agkanban writable roots to Codex config.toml

Usage:
  setup-codex-sandbox.sh [--config PATH] [--check|--print]

Options:
  --config PATH  config file to update (default: $CODEX_HOME/config.toml or ~/.codex/config.toml)
  --check        report whether required roots are present; do not write
  --print        print the TOML block that should be present; do not write
  -h, --help     show this help
USAGE
}

MODE="write"
CONFIG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG="${2:?--config needs a path}"
      shift 2
      ;;
    --check)
      MODE="check"
      shift
      ;;
    --print)
      MODE="print"
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "setup-codex-sandbox: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

expand_path() {
  local p="$1"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#~/}" ;;
  esac
  p="${p%/}"
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *) printf '%s/%s\n' "$(pwd)" "$p" ;;
  esac
}

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

codex_config_path() {
  if [ -n "$CONFIG" ]; then
    expand_path "$CONFIG"
    return
  fi
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  printf '%s/config.toml\n' "$(expand_path "$codex_home")"
}

required_roots() {
  expand_path "${AGKANBAN_STORAGE_PATH:-$HOME/.agkanban}"
  expand_path "${AGMSG_HOME:-$HOME/.agents/skills/agmsg}"
  if [ -n "${AGMSG_STORAGE_PATH:-}" ]; then
    expand_path "$AGMSG_STORAGE_PATH"
  fi
}

print_roots_block() {
  local root
  echo "[sandbox_workspace_write]"
  echo "writable_roots = ["
  required_roots | awk 'length($0) && !seen[$0]++' | while IFS= read -r root; do
    printf '  "%s",\n' "$(toml_escape "$root")"
  done
  echo "]"
}

extract_roots() { # config
  local config="$1"
  [ -f "$config" ] || return 0
  awk '
    /^\[sandbox_workspace_write\][[:space:]]*$/ { inside=1; next }
    /^\[/ { inside=0; capture=0 }
    inside {
      if ($0 ~ /^[[:space:]]*writable_roots[[:space:]]*=/) capture=1
      if (capture) {
        line=$0
        while (match(line, /"([^"\\]|\\.)*"/)) {
          s=substr(line, RSTART + 1, RLENGTH - 2)
          gsub(/\\"/, "\"", s)
          gsub(/\\\\/, "\\", s)
          print s
          line=substr(line, RSTART + RLENGTH)
        }
        if ($0 ~ /\]/) capture=0
      }
    }
  ' "$config"
}

merged_roots_file() { # config out_file
  local config="$1" out="$2"
  {
    extract_roots "$config"
    required_roots
  } | awk 'length($0) && !seen[$0]++' > "$out"
}

missing_roots() { # config
  local config="$1" tmp existing root
  tmp="$(mktemp "${TMPDIR:-/tmp}/agkanban-roots.XXXXXX")"
  extract_roots "$config" > "$tmp"
  while IFS= read -r root; do
    if ! grep -Fx -- "$root" "$tmp" >/dev/null 2>&1; then
      printf '%s\n' "$root"
    fi
  done < <(required_roots | awk 'length($0) && !seen[$0]++')
  rm -f "$tmp"
}

rewrite_config() { # config merged_roots_file
  local config="$1" roots_file="$2" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/agkanban-config.XXXXXX")"
  if [ -f "$config" ]; then
    awk -v roots_file="$roots_file" '
      function emit_roots(  root) {
        print "writable_roots = ["
        while ((getline root < roots_file) > 0) {
          gsub(/\\/, "\\\\", root)
          gsub(/"/, "\\\"", root)
          print "  \"" root "\","
        }
        close(roots_file)
        print "]"
      }

      /^\[sandbox_workspace_write\][[:space:]]*$/ {
        saw_section=1
        inside=1
        inserted=0
        skipping=0
        print
        next
      }

      /^\[/ {
        if (inside && !inserted) {
          emit_roots()
          inserted=1
        }
        inside=0
        skipping=0
        print
        next
      }

      inside && skipping {
        if ($0 ~ /\]/) skipping=0
        next
      }

      inside && $0 ~ /^[[:space:]]*writable_roots[[:space:]]*=/ {
        if (!inserted) {
          emit_roots()
          inserted=1
        }
        if ($0 !~ /\]/) skipping=1
        next
      }

      { print }

      END {
        if (inside && !inserted) {
          emit_roots()
          inserted=1
        }
        if (!saw_section) {
          if (NR > 0) print ""
          print "[sandbox_workspace_write]"
          emit_roots()
        }
      }
    ' "$config" > "$tmp"
  else
    {
      echo "[sandbox_workspace_write]"
      awk 'BEGIN { print "writable_roots = [" }
        {
          root=$0
          gsub(/\\/, "\\\\", root)
          gsub(/"/, "\\\"", root)
          print "  \"" root "\","
        }
        END { print "]" }' "$roots_file"
    } > "$tmp"
  fi
  mv "$tmp" "$config"
}

CONFIG_PATH="$(codex_config_path)"

case "$MODE" in
  print)
    print_roots_block
    exit 0
    ;;
  check)
    missing="$(missing_roots "$CONFIG_PATH")"
    if [ -z "$missing" ]; then
      echo "Codex sandbox writable roots already include agkanban paths: $CONFIG_PATH"
      exit 0
    fi
    echo "Codex sandbox writable roots missing from $CONFIG_PATH:"
    printf '%s\n' "$missing"
    exit 1
    ;;
esac

mkdir -p "$(dirname "$CONFIG_PATH")"
mkdir -p "$(expand_path "${AGKANBAN_STORAGE_PATH:-$HOME/.agkanban}")"

if [ -z "$(missing_roots "$CONFIG_PATH")" ]; then
  echo "Codex sandbox writable roots already include agkanban paths: $CONFIG_PATH"
  exit 0
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agkanban-setup.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
ROOTS_FILE="$WORK_DIR/roots"
merged_roots_file "$CONFIG_PATH" "$ROOTS_FILE"

if [ -f "$CONFIG_PATH" ]; then
  cp "$CONFIG_PATH" "$CONFIG_PATH.bak"
fi

BEFORE=""
[ -f "$CONFIG_PATH" ] && BEFORE="$(cat "$CONFIG_PATH")"
rewrite_config "$CONFIG_PATH" "$ROOTS_FILE"
AFTER="$(cat "$CONFIG_PATH")"

if [ "$AFTER" = "$BEFORE" ]; then
  echo "Codex sandbox writable roots already include agkanban paths: $CONFIG_PATH"
else
  echo "Updated Codex sandbox writable roots: $CONFIG_PATH"
  if [ -f "$CONFIG_PATH.bak" ]; then
    echo "Backup: $CONFIG_PATH.bak"
  fi
fi
