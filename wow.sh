#!/usr/bin/env bash
# MaxPlus AI — one-liner installer for Claude Code + Codex CLI
# Usage:
#   curl -fsSL https://maxplus-ai.cc/install.sh | bash -s ccsk-yourkey
#   curl -fsSL https://maxplus-ai.cc/install.sh | bash             # will prompt
#
# Env overrides:
#   MAXPLUS_ENDPOINT    — default http://localhost:20128/v1
#   MAXPLUS_SKIP_CODEX  — set to 1 to skip @openai/codex install
#
# Security model:
#  * Delivered over HTTPS only (HSTS on apex). Cache-Control set so CF caches
#    at edge → resists DDoS without exposing origin.
#  * The entire installer body is wrapped in __maxplus_install_main() and only
#    invoked on the LAST line. A truncated `curl | bash` (network drop) will
#    fail to parse the function and exit BEFORE any side effect occurs — this
#    closes the well-known partial-download class of curl|bash exploits.
#  * API key is validated against the strict shape ^ccsk-[a-f0-9]{64}$ before
#    being interpolated anywhere — no shell metacharacters can leak through.

__maxplus_install_main() {
  set -euo pipefail

  local API_KEY="${1:-}"
  local ENDPOINT="${MAXPLUS_ENDPOINT:-http://localhost:20128/v1}"
  local SKIP_CODEX="${MAXPLUS_SKIP_CODEX:-0}"
  local CREDENTIAL_ENV_VARS=(
    ANTHROPIC_BASE_URL
    ANTHROPIC_API_KEY
    ANTHROPIC_AUTH_TOKEN
    ANTHROPIC_TOKEN
    CLAUDE_CODE_OAUTH_TOKEN
    OPENAI_BASE_URL
    OPENAI_API_KEY
    MAXPLUS_API_KEY
  )

  local c_red=$'\033[31m' c_grn=$'\033[32m' c_yel=$'\033[33m' c_blu=$'\033[34m'
  local c_dim=$'\033[2m' c_bld=$'\033[1m' c_rst=$'\033[0m'
  _log()  { printf "%s==>%s %s\n" "$c_blu" "$c_rst" "$*"; }
  _ok()   { printf "%s ✓%s  %s\n" "$c_grn" "$c_rst" "$*"; }
  _warn() { printf "%s ⚠%s  %s\n" "$c_yel" "$c_rst" "$*"; }
  _die()  { printf "%s ✗%s  %s\n" "$c_red" "$c_rst" "$*" >&2; exit 1; }

  printf "\n%s%sMaxPlus AI installer%s\n" "$c_bld" "$c_blu" "$c_rst"
  printf "%shttps://maxplus-ai.cc%s\n\n" "$c_dim" "$c_rst"

  unset "${CREDENTIAL_ENV_VARS[@]}" 2>/dev/null || true

  # ── 1. Endpoint validation (allow https://*.maxplus-ai.cc OR http://localhost:20128/v1) ───
  if [[ ! "$ENDPOINT" =~ ^https://[a-zA-Z0-9.-]+\.maxplus-ai\.cc$ ]] && [[ "$ENDPOINT" != "http://localhost:20128/v1" ]]; then
    _die "MAXPLUS_ENDPOINT must be an https://*.maxplus-ai.cc URL or http://localhost:20128/v1 (got: $ENDPOINT)"
  fi

  # ── 2. API key (prompt if missing, validate strict shape) ─────────
  if [ -z "$API_KEY" ]; then
    if [ -e /dev/tty ]; then
      printf "Paste your MaxPlus API key (ccsk-...): "
      read -r API_KEY < /dev/tty || true
      printf "\n"
    fi
  fi
  # Strict shape: ccsk- + 64 lowercase hex chars. Same gate as the proxy's
  # findKey() — anything else is rejected before we ever interpolate it.
  if [[ ! "$API_KEY" =~ ^ccsk-[a-f0-9]{64}$ ]]; then
    _die "API key must match shape ccsk-[64 lowercase hex chars]. Get one at ${ENDPOINT%/}/dashboard"
  fi

  # ── 3. Node ───────────────────────────────────────────────────────
  command -v node >/dev/null 2>&1 || _die "Node.js 20+ is required. Install from https://nodejs.org/ (or use nvm)."
  local NODE_MAJOR
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [ "$NODE_MAJOR" -ge 20 ] || _die "Node.js >= 20 required (you have $(node -v 2>/dev/null || echo unknown))"
  command -v npm  >/dev/null 2>&1 || _die "npm not found alongside node — broken install?"
  _ok "node $(node -v) detected"

  # ── 4. Install CLIs ───────────────────────────────────────────────
  _log "Installing @anthropic-ai/claude-code (global)..."
  if ! npm install -g @anthropic-ai/claude-code --silent 2>/tmp/maxplus-npm.log; then
    if grep -qiE 'EACCES|permission denied' /tmp/maxplus-npm.log; then
      _warn "npm denied write to global prefix — retrying with sudo (you'll be prompted)"
      sudo -E npm install -g @anthropic-ai/claude-code --silent || _die "claude-code install failed"
    else
      cat /tmp/maxplus-npm.log >&2
      _die "claude-code install failed (see log above)"
    fi
  fi
  _ok "claude-code installed"

  if [ "$SKIP_CODEX" != "1" ]; then
    _log "Installing @openai/codex (global)..."
    if ! npm install -g @openai/codex --silent 2>/tmp/maxplus-npm.log; then
      if grep -qiE 'EACCES|permission denied' /tmp/maxplus-npm.log; then
        sudo -E npm install -g @openai/codex --silent || _warn "codex install failed (continuing)"
      else
        _warn "codex install failed (continuing) — see /tmp/maxplus-npm.log"
      fi
    else
      _ok "codex installed"
    fi
  fi

  # ── 5. Pre-seed Claude Code onboarding (skips OAuth wizard) ───────
  mkdir -p "$HOME/.claude"
  local CLAUDE_JSON="$HOME/.claude.json"
  node - "$CLAUDE_JSON" "$API_KEY" <<'NODE'
const fs = require("fs");
const [, , f, tok] = process.argv;
let j = {};
try { j = JSON.parse(fs.readFileSync(f, "utf8") || "{}"); } catch (_) {}
j.hasCompletedOnboarding = true;
j.bypassPermissionsModeAccepted = true;
const keyTail = String(tok).slice(-20);
const r = (j.customApiKeyResponses && typeof j.customApiKeyResponses === "object") ? j.customApiKeyResponses : {};
const approved = Array.isArray(r.approved) ? r.approved.slice() : [];
const rejected = Array.isArray(r.rejected) ? r.rejected.slice() : [];
if (!approved.includes(keyTail)) approved.push(keyTail);
j.customApiKeyResponses = { approved, rejected };
fs.writeFileSync(f, JSON.stringify(j, null, 2));
NODE
  _ok "wrote $CLAUDE_JSON (skip OAuth wizard + pre-approve API key)"

  # ── 6. settings.json with env block (merge if exists) ─────────────
  local SETTINGS="$HOME/.claude/settings.json"
  node - "$SETTINGS" "$ENDPOINT" "$API_KEY" <<'NODE'
const fs = require("fs");
const [, , f, ep, tok] = process.argv;
let j = {};
try { j = JSON.parse(fs.readFileSync(f, "utf8") || "{}"); } catch (_) {}
j.hasCompletedOnboarding = true;
if (j.cleanupPeriodDays == null) j.cleanupPeriodDays = 30;
j.env = Object.assign({}, j.env || {}, {
  ANTHROPIC_BASE_URL: ep,
  ANTHROPIC_API_KEY: tok,
  CLAUDE_CODE_ATTRIBUTION_HEADER: "0",
});
delete j.env.ANTHROPIC_AUTH_TOKEN;
const keyTail = String(tok).slice(-20);
const r = (j.customApiKeyResponses && typeof j.customApiKeyResponses === "object") ? j.customApiKeyResponses : {};
const approved = Array.isArray(r.approved) ? r.approved.slice() : [];
const rejected = Array.isArray(r.rejected) ? r.rejected.slice() : [];
if (!approved.includes(keyTail)) approved.push(keyTail);
j.customApiKeyResponses = { approved, rejected };
if (!j.permissions) {
  j.permissions = {
    allow: [
      "Edit", "Read", "Write", "Bash", "Agent", "Glob", "Grep",
      "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskStop",
      "WebSearch", "WebFetch", "NotebookEdit", "Skill", "AskUserQuestion",
      "EnterPlanMode", "ExitPlanMode"
    ],
    deny: [],
    ask: [],
    defaultMode: "bypassPermissions",
  };
}
if (!j.model) j.model = "opus[1m]";
fs.writeFileSync(f, JSON.stringify(j, null, 2));
NODE
  _ok "wrote $SETTINGS"

  chmod 600 "$SETTINGS" "$CLAUDE_JSON" 2>/dev/null || true

  # ── 7. Wipe stale OAuth credentials ───────────────────────────────
  rm -f "$HOME/.claude/.credentials.json" "$HOME/.claude/auth.json" 2>/dev/null || true

  # ── 8. Codex config.toml + auth.json ──────────────────────────────
  mkdir -p "$HOME/.codex"
  local CODEX_TOML="$HOME/.codex/config.toml"
  local CODEX_PROFILE="$HOME/.codex/maxplus.config.toml"
  cat > "$CODEX_TOML" <<EOF
# Generated by MaxPlus AI installer ($(date -u +%FT%TZ))
model_provider = "maxplus"
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
disable_response_storage = true

[model_providers.maxplus]
name = "MaxPlus AI"
base_url = "${ENDPOINT}"
wire_api = "responses"
EOF
  _ok "wrote $CODEX_TOML"

  cat > "$CODEX_PROFILE" <<EOF
# Generated by MaxPlus AI installer ($(date -u +%FT%TZ))
model_provider = "maxplus"
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
EOF
  _ok "wrote $CODEX_PROFILE"

  local CODEX_AUTH="$HOME/.codex/auth.json"
  node - "$CODEX_AUTH" "$API_KEY" <<'NODE'
const fs = require("fs");
const [, , f, tok] = process.argv;
fs.writeFileSync(f, JSON.stringify({ OPENAI_API_KEY: tok }, null, 2) + "\n");
NODE
  chmod 600 "$CODEX_AUTH" 2>/dev/null || true
  _ok "wrote $CODEX_AUTH"

  # ── 9. Remove stale user-level env exports ────────────────────────
  _scrub_shell_env_files() {
    local MARK="# >>> MaxPlus AI >>>"
    local END_MARK="# <<< MaxPlus AI <<<"
    local VARS='(ANTHROPIC_BASE_URL|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|OPENAI_BASE_URL|OPENAI_API_KEY|MAXPLUS_API_KEY)'
    local RC_FILES=(
      "$HOME/.zshrc"
      "$HOME/.zprofile"
      "$HOME/.bashrc"
      "$HOME/.bash_profile"
      "$HOME/.profile"
      "$HOME/.config/fish/config.fish"
    )
    local rc tmp touched=0

    for rc in "${RC_FILES[@]}"; do
      [ -f "$rc" ] || continue
      tmp="$(mktemp)"
      awk -v m="$MARK" -v e="$END_MARK" -v vars="$VARS" '
        $0==m { skip=1; changed=1; next }
        $0==e { skip=0; next }
        skip { changed=1; next }
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?" vars "=" { changed=1; next }
        $0 ~ "^[[:space:]]*set[[:space:]]+-[[:alpha:]]*x[[:space:]]+" vars "([[:space:]]|$)" { changed=1; next }
        $0 ~ "^[[:space:]]*set[[:space:]]+-[[:alpha:]]*e[[:alpha:]]*[[:space:]]+" vars "([[:space:]]|$)" { changed=1; next }
        { print }
      ' "$rc" > "$tmp"
      if ! cmp -s "$rc" "$tmp"; then
        mv "$tmp" "$rc"
        touched=$((touched + 1))
      else
        rm -f "$tmp"
      fi
    done

    if command -v fish >/dev/null 2>&1; then
      fish -c 'for v in ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_TOKEN CLAUDE_CODE_OAUTH_TOKEN OPENAI_BASE_URL OPENAI_API_KEY MAXPLUS_API_KEY; set -eU $v 2>/dev/null; end' >/dev/null 2>&1 || true
    fi

    if [ "$touched" -gt 0 ]; then
      _ok "removed stale Claude/Codex env exports from shell rc files"
    else
      _ok "no shell rc credential env exports to remove"
    fi
  }
  _scrub_shell_env_files

  # ── 10. Smoke test ────────────────────────────────────────────────
  _log "Smoke-testing $ENDPOINT/messages ..."
  local HTTP_CODE
  HTTP_CODE="$(curl -sS --max-time 30 -o /tmp/maxplus-smoke.json -w '%{http_code}' \
    -X POST "$ENDPOINT/messages" \
    -H "x-api-key: $API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":16,"messages":[{"role":"user","content":"pong"}]}' \
    2>/dev/null || echo 000)"
  case "$HTTP_CODE" in
    200) _ok "endpoint responded 200 — key works" ;;
    402) _warn "endpoint OK but credit empty (HTTP 402) — top up at ${ENDPOINT%/}/dashboard/topup" ;;
    401|403) _warn "endpoint rejected the key (HTTP $HTTP_CODE) — re-create one at https://maxplus-ai.cc/dashboard" ;;
    000) _warn "could not reach $ENDPOINT — check network / DNS / firewall" ;;
    *)   _warn "smoke test got HTTP $HTTP_CODE — body at /tmp/maxplus-smoke.json" ;;
  esac

  cat <<EOF

${c_grn}${c_bld}Done!${c_rst} MaxPlus AI is installed.

  ${c_blu}Claude Code:${c_rst}  open a new terminal, then run  ${c_bld}claude${c_rst}
  ${c_blu}Codex CLI:${c_rst}    open a new terminal, then run  ${c_bld}codex${c_rst}

Manage credit & keys:  https://maxplus-ai.cc/dashboard
Need help:             https://maxplus-ai.cc/getterstart

${c_yel}Important:${c_rst} if an old terminal still has API env vars loaded, close it and open a new one.
EOF
}

__maxplus_install_main "$@"
