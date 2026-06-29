#!/usr/bin/env bash
# monitor.sh — roda no SERVIDOR (host)
# Fluxo:
#   1. Polling do GitHub a cada POLL_INTERVAL segundos
#   2. Novo commit → baixa wine67.sh
#   3. Envia wine67.sh via vsock + sinal RUN
#   4. Aguarda sinal DONE + relatório da VM
#   5. Analisa via Groq → salva log → envia email

set -euo pipefail

# ══════════════════════════════════════════════════════════════════
# CONFIGURAÇÃO — edite aqui ou exporte as variáveis antes de rodar
# ══════════════════════════════════════════════════════════════════
GITHUB_REPO="${GITHUB_REPO:-gabrieldeisrael/wine67}"          # user/repo no GitHub
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"                         # branch a monitorar
GITHUB_FILE="${GITHUB_FILE:-wine67.sh}"                        # arquivo a baixar
POLL_INTERVAL="${POLL_INTERVAL:-300}"                          # segundos entre checks (default 5 min)

VSOCK_PORT="${VSOCK_PORT:-9967}"                               # porta vsock
VM_CID="${VM_CID:-3}"                                          # CID da VM (3 = primeira VM KVM/QEMU)

GROQ_API_KEY="${GROQ_API_KEY:-}"                               # chave Groq Cloud
GMAIL_USER="${GMAIL_USER:-}"                                    # remetente Gmail
GMAIL_APP_PASSWORD="${GMAIL_APP_PASSWORD:-}"                    # App Password Gmail
EMAIL_DESTINO="${EMAIL_DESTINO:-}"                              # destinatário

LOG_DIR="${LOG_DIR:-$HOME/.local/share/wine67ci/logs}"
STATE_FILE="${STATE_FILE:-$HOME/.local/share/wine67ci/last_commit}"
# ══════════════════════════════════════════════════════════════════

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$STATE_FILE")"

# ── Helpers ───────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "[ERRO] $*" >&2; exit 1; }

# ── Verifica dependências ─────────────────────────────────────────
for cmd in curl python3 socat; do
    command -v "$cmd" &>/dev/null || die "$cmd não encontrado. Instale antes de continuar."
done

# ── Busca SHA do último commit do arquivo no GitHub ───────────────
get_remote_sha() {
    curl -sf \
        "https://api.github.com/repos/${GITHUB_REPO}/commits?sha=${GITHUB_BRANCH}&path=${GITHUB_FILE}&per_page=1" \
        | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['sha'])" 2>/dev/null \
        || echo ""
}

# ── Baixa o wine67.sh do commit mais recente ─────────────────────
download_script() {
    local sha="$1"
    local dest="$2"
    local url="https://raw.githubusercontent.com/${GITHUB_REPO}/${sha}/${GITHUB_FILE}"
    log "Baixando $GITHUB_FILE @ ${sha:0:8} ..."
    curl -sf "$url" -o "$dest" || die "Falha ao baixar $url"
    chmod +x "$dest"
}

# ── Envia dados via vsock (usando socat) ──────────────────────────
# Protocolo de mensagem:
#   <TAMANHO_EM_BYTES_10_DIGITOS><CONTEUDO>
# Isso permite que o receptor saiba exatamente quantos bytes ler.

vsock_send_file() {
    local file="$1"
    local size
    size=$(wc -c < "$file")
    local header
    header=$(printf '%010d' "$size")
    log "Enviando arquivo via vsock (${size} bytes) ..."
    { printf '%s' "$header"; cat "$file"; } \
        | socat - "VSOCK-CONNECT:${VM_CID}:${VSOCK_PORT}" \
        || die "Falha ao enviar arquivo via vsock"
}

vsock_send_signal() {
    local signal="$1"
    log "Enviando sinal: $signal"
    printf '%010d%s' "${#signal}" "$signal" \
        | socat - "VSOCK-CONNECT:${VM_CID}:${VSOCK_PORT}" \
        || die "Falha ao enviar sinal via vsock"
}

# ── Recebe dados via vsock ────────────────────────────────────────
vsock_recv() {
    local timeout="${1:-120}"
    # Lê header de 10 bytes → depois lê exatamente esse número de bytes
    socat -T "$timeout" "VSOCK-LISTEN:${VSOCK_PORT},reuseaddr" - 2>/dev/null | {
        read -r -n 10 header
        local size="${header// /}"
        if [[ -z "$size" || ! "$size" =~ ^[0-9]+$ ]]; then
            echo ""
            return
        fi
        dd bs=1 count="$size" 2>/dev/null
    }
}

# ── Análise via Groq ──────────────────────────────────────────────
analyze_with_groq() {
    local report="$1"
    [[ -z "$GROQ_API_KEY" ]] && { echo "$report"; return; }

    local prompt="Você é um assistente de QA analisando logs de testes do wine67.sh.
Os testes executaram 5 arquivos .exe e coletaram se cada um crashou ou não.

Analise os logs abaixo e gere um relatório em português brasileiro com:
1. Resumo Executivo (2-3 frases)
2. Resultado por .exe (tabela: nome | status | erro se houver)
3. Padrões de falha encontrados
4. Recomendações
5. Status Final: ✅ TUDO OK ou ❌ AÇÃO NECESSÁRIA

Logs:
$report"

    local prompt_escaped
    prompt_escaped=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read())[1:-1])" <<< "$prompt")

    local payload="{\"model\":\"llama3-70b-8192\",\"max_tokens\":2048,\"messages\":[{\"role\":\"user\",\"content\":\"$prompt_escaped\"}]}"

    local response
    response=$(curl -sf \
        -X POST "https://api.groq.com/openai/v1/chat/completions" \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload") || { echo "$report"; return; }

    python3 -c "
import json,sys
data = json.load(sys.stdin)
print(data['choices'][0]['message']['content'])
" <<< "$response" || echo "$report"
}

# ── Envia email via Gmail SMTP ────────────────────────────────────
send_email() {
    local report_file="$1"
    local commit_sha="$2"
    [[ -z "$GMAIL_USER" || -z "$GMAIL_APP_PASSWORD" || -z "$EMAIL_DESTINO" ]] && {
        log "[email] Credenciais não configuradas, pulando envio."
        return
    }

    local subject="[wine67ci] Relatório @ ${commit_sha:0:8} — $(date '+%d/%m/%Y %H:%M')"
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" << EOF
From: wine67ci <$GMAIL_USER>
To: $EMAIL_DESTINO
Subject: $subject
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit

$(cat "$report_file")
EOF

    log "Enviando email para $EMAIL_DESTINO ..."
    if curl -sf \
        --url "smtps://smtp.gmail.com:465" \
        --ssl-reqd \
        --mail-from "$GMAIL_USER" \
        --mail-rcpt "$EMAIL_DESTINO" \
        --user "$GMAIL_USER:$GMAIL_APP_PASSWORD" \
        --upload-file "$tmp"; then
        log "✅ Email enviado."
    else
        log "❌ Falha ao enviar email."
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
        log "Não foi possível obter SHA (sem internet ou repo privado sem token)."
    elif [[ "$CURRENT_SHA" == "$LAST_SHA" ]]; then
        log "Sem novidades. Próximo check em ${POLL_INTERVAL}s."
    else
        log "🔔 Novo commit detectado: ${CURRENT_SHA:0:8} (anterior: ${LAST_SHA:0:8:-}"

        TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
        TMP_SCRIPT=$(mktemp /tmp/wine67_XXXXXX.sh)
        LOG_FILE="$LOG_DIR/relatorio_${TIMESTAMP}.txt"

        # 1. Baixa o script
        download_script "$CURRENT_SHA" "$TMP_SCRIPT"

        # 2. Envia o arquivo para a VM
        vsock_send_file "$TMP_SCRIPT"
        sleep 1

        # 3. Envia sinal RUN
        vsock_send_signal "RUN:${CURRENT_SHA:0:8}"

        rm -f "$TMP_SCRIPT"

        # 4. Aguarda relatório da VM (timeout 10 min)
        log "Aguardando relatório da VM (timeout 10 min) ..."
        RAW_REPORT=$(vsock_recv 600)

        if [[ -z "$RAW_REPORT" ]]; then
            log "❌ Timeout ou sem resposta da VM."
            RAW_REPORT="[ERRO] Nenhum relatório recebido da VM em 10 minutos."
        else
            log "✅ Relatório recebido (${#RAW_REPORT} bytes)."
        fi

        # 5. Analisa com Groq
        log "Analisando com Groq ..."
        FINAL_REPORT=$(analyze_with_groq "$RAW_REPORT")

        # 6. Salva log
        {
            echo "=== wine67ci — Relatório ==="
            echo "Commit : $CURRENT_SHA"
            echo "Data   : $(date '+%d/%m/%Y %H:%M:%S')"
            echo "=========================="
            echo ""
            echo "$FINAL_REPORT"
            echo ""
            echo "=== Log bruto da VM ==="
            echo "$RAW_REPORT"
        } > "$LOG_FILE"
        log "Log salvo: $LOG_FILE"

        # 7. Envia email
        send_email "$LOG_FILE" "$CURRENT_SHA"

        # 8. Atualiza estado
        echo "$CURRENT_SHA" > "$STATE_FILE"
        LAST_SHA="$CURRENT_SHA"
    fi

    sleep "$POLL_INTERVAL"
done
