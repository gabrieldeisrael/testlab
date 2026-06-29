#!/usr/bin/env bash
# monitor.sh — roda no SERVIDOR (host)
# Fluxo:
#   1. Polling do GitHub a cada POLL_INTERVAL segundos
#   2. Novo commit → baixa wine67.sh
#   3. Envia wine67.sh via vsock + sinal RUN
#   4. Aguarda relatório da VM
#   5. Analisa via Groq → salva log → envia email

set -euo pipefail

# ══════════════════════════════════════════════════════════════════
# CONFIGURAÇÃO — edite aqui ou exporte as variáveis antes de rodar
# ══════════════════════════════════════════════════════════════════
GITHUB_REPO="${GITHUB_REPO:-gabrieldeisrael/Wine67}"   # case-sensitive!
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_FILE="${GITHUB_FILE:-wine67.sh}"
POLL_INTERVAL="${POLL_INTERVAL:-300}"                   # segundos (default 5 min)

VSOCK_PORT="${VSOCK_PORT:-9967}"
VM_CID="${VM_CID:-3}"                                  # CID da VM KVM/QEMU

GROQ_API_KEY="${GROQ_API_KEY:-}"
GMAIL_USER="${GMAIL_USER:-}"
GMAIL_APP_PASSWORD="${GMAIL_APP_PASSWORD:-}"
EMAIL_DESTINO="${EMAIL_DESTINO:-}"

LOG_DIR="${LOG_DIR:-$HOME/.local/share/wine67ci/logs}"
STATE_FILE="${STATE_FILE:-$HOME/.local/share/wine67ci/last_commit}"
# ══════════════════════════════════════════════════════════════════

mkdir -p "$LOG_DIR" "$(dirname "$STATE_FILE")"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[ERRO] $*" >&2; exit 1; }

for cmd in curl python3 socat; do
    command -v "$cmd" &>/dev/null || die "$cmd não encontrado."
done

# ── SHA do último commit do wine67.sh no GitHub ──────────────────
get_remote_sha() {
    curl -sf \
        "https://api.github.com/repos/${GITHUB_REPO}/commits?sha=${GITHUB_BRANCH}&path=${GITHUB_FILE}&per_page=1" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['sha'])" 2>/dev/null \
        || echo ""
}

# ── Baixa o wine67.sh do commit ──────────────────────────────────
download_script() {
    local sha="$1" dest="$2"
    local url="https://raw.githubusercontent.com/${GITHUB_REPO}/${sha}/${GITHUB_FILE}"
    log "Baixando $GITHUB_FILE @ ${sha:0:8} ..."
    curl -sf "$url" -o "$dest" || die "Falha ao baixar $url"
    chmod +x "$dest"
}

# ── Protocolo vsock: header 10 dígitos + payload ─────────────────
vsock_send_file() {
    local file="$1"
    local size
    size=$(wc -c < "$file")
    log "Enviando wine67.sh via vsock (${size} bytes) ..."
    { printf '%010d' "$size"; cat "$file"; } \
        | socat - "VSOCK-CONNECT:${VM_CID}:${VSOCK_PORT}" \
        || die "Falha ao enviar via vsock. VM está ligada e agente.sh rodando?"
}

vsock_send_signal() {
    local sig="$1"
    log "Enviando sinal: $sig"
    printf '%010d%s' "${#sig}" "$sig" \
        | socat - "VSOCK-CONNECT:${VM_CID}:${VSOCK_PORT}" \
        || die "Falha ao enviar sinal via vsock"
}

vsock_recv() {
    local tout="${1:-120}"
    socat -T "$tout" "VSOCK-LISTEN:${VSOCK_PORT},reuseaddr" - 2>/dev/null | {
        IFS= read -r -n 10 header
        local size="${header// /}"
        [[ -z "$size" || ! "$size" =~ ^[0-9]+$ ]] && return
        dd bs=1 count="$size" 2>/dev/null
    }
}

# ── Análise via Groq ──────────────────────────────────────────────
analyze_with_groq() {
    local report="$1"
    [[ -z "$GROQ_API_KEY" ]] && { echo "$report"; return; }

    local prompt
    prompt="Você é um assistente de QA analisando logs do wine67.sh (Wine portátil sem sudo).
O agente de CI rodou até 5 arquivos .exe via Wine e coletou se cada um crashou ou não.

Analise os logs abaixo e gere um relatório em português brasileiro com:
1. Resumo Executivo (2-3 frases)
2. Resultado por .exe (tabela: nome | status | detalhe)
3. Padrões de falha encontrados (ex: crash consistente, timeout, erro de prefix)
4. Recomendações
5. Status Final: ✅ TUDO OK ou ❌ AÇÃO NECESSÁRIA

Logs:
$report"

    local escaped
    escaped=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read())[1:-1])" <<< "$prompt")
    local payload="{\"model\":\"llama3-70b-8192\",\"max_tokens\":2048,\"messages\":[{\"role\":\"user\",\"content\":\"$escaped\"}]}"

    local resp
    resp=$(curl -sf \
        -X POST "https://api.groq.com/openai/v1/chat/completions" \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload") || { log "Groq falhou, usando log bruto."; echo "$report"; return; }

    python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['choices'][0]['message']['content'])
" <<< "$resp" || { log "Parse Groq falhou, usando log bruto."; echo "$report"; }
}

# ── Email via Gmail SMTP ──────────────────────────────────────────
send_email() {
    local report_file="$1" sha="$2"
    [[ -z "$GMAIL_USER" || -z "$GMAIL_APP_PASSWORD" || -z "$EMAIL_DESTINO" ]] && {
        log "[email] Credenciais não configuradas, pulando."; return
    }

    local subject="[wine67ci] Relatório @ ${sha:0:8} — $(date '+%d/%m/%Y %H:%M')"
    local tmp; tmp=$(mktemp)
    {
        echo "From: wine67ci <$GMAIL_USER>"
        echo "To: $EMAIL_DESTINO"
        echo "Subject: $subject"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        cat "$report_file"
    } > "$tmp"

    log "Enviando email para $EMAIL_DESTINO ..."
    if curl -sf \
        --url "smtps://smtp.gmail.com:465" --ssl-reqd \
        --mail-from "$GMAIL_USER" --mail-rcpt "$EMAIL_DESTINO" \
        --user "$GMAIL_USER:$GMAIL_APP_PASSWORD" \
        --upload-file "$tmp"; then
        log "✅ Email enviado."
    else
        log "❌ Falha no email."
    fi
    rm -f "$tmp"
}

# ══════════════════════════════════════════════════════════════════
# LOOP PRINCIPAL
# ══════════════════════════════════════════════════════════════════
log "=== wine67ci monitor iniciado (polling a cada ${POLL_INTERVAL}s) ==="
log "    Repo   : $GITHUB_REPO @ $GITHUB_BRANCH"
log "    Arquivo: $GITHUB_FILE"
log "    VM CID : $VM_CID  Porta: $VSOCK_PORT"

LAST_SHA=""
[[ -f "$STATE_FILE" ]] && LAST_SHA=$(cat "$STATE_FILE")

while true; do
    log "Checando GitHub ..."
    CURRENT_SHA=$(get_remote_sha)

    if [[ -z "$CURRENT_SHA" ]]; then
        log "⚠ Não foi possível obter SHA (sem internet ou rate limit da API GitHub)."

    elif [[ "$CURRENT_SHA" == "$LAST_SHA" ]]; then
        log "Sem novidades. Próximo check em ${POLL_INTERVAL}s."

    else
        log "🔔 Novo commit: ${CURRENT_SHA:0:8} (anterior: ${LAST_SHA:0:8})"

        TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
        TMP_SCRIPT=$(mktemp /tmp/wine67_XXXXXX.sh)
        LOG_FILE="$LOG_DIR/relatorio_${TIMESTAMP}_${CURRENT_SHA:0:8}.txt"

        download_script "$CURRENT_SHA" "$TMP_SCRIPT"

        # Envia script e aguarda agente estar em escuta
        vsock_send_file "$TMP_SCRIPT"
        sleep 1

        # Envia sinal RUN com SHA curto
        vsock_send_signal "RUN:${CURRENT_SHA:0:8}"
        rm -f "$TMP_SCRIPT"

        # Aguarda relatório — timeout generoso pois wine67.sh pode baixar o Wine (~500MB)
        # na primeira execução: 30 min
        log "Aguardando relatório da VM (timeout 30 min) ..."
        RAW_REPORT=$(vsock_recv 1800)

        if [[ -z "$RAW_REPORT" ]]; then
            log "❌ Timeout — sem resposta da VM em 30 minutos."
            RAW_REPORT="[ERRO] Nenhum relatório recebido da VM. Possíveis causas:
- wine67.sh ainda baixando Wine (~500MB na primeira execução)
- wineboot demorou mais que o esperado
- agente.sh crashou (verifique journalctl na VM)"
        else
            log "✅ Relatório recebido (${#RAW_REPORT} bytes)."
        fi

        log "Analisando com Groq ..."
        FINAL_REPORT=$(analyze_with_groq "$RAW_REPORT")

        {
            echo "=== wine67ci — Relatório Final ==="
            echo "Commit  : $CURRENT_SHA"
            echo "Data    : $(date '+%d/%m/%Y %H:%M:%S')"
            echo "Repo    : $GITHUB_REPO @ $GITHUB_BRANCH"
            echo "=================================="
            echo ""
            echo "$FINAL_REPORT"
            echo ""
            echo "=== Log bruto da VM ==="
            echo "$RAW_REPORT"
        } > "$LOG_FILE"
        log "Log salvo: $LOG_FILE"

        send_email "$LOG_FILE" "$CURRENT_SHA"

        echo "$CURRENT_SHA" > "$STATE_FILE"
        LAST_SHA="$CURRENT_SHA"
    fi

    sleep "$POLL_INTERVAL"
done
