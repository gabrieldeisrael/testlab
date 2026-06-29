#!/usr/bin/env bash
# agente.sh — roda na VM (guest)
# Fluxo:
#   1. Fica escutando na porta vsock
#   2. Recebe wine67.sh do servidor
#   3. Recebe sinal RUN
#   4. Instala wine67.sh, roda os 5 .exe e coleta logs
#   5. Envia relatório de volta via vsock

set -euo pipefail

# ══════════════════════════════════════════════════════════════════
# CONFIGURAÇÃO
# ══════════════════════════════════════════════════════════════════
VSOCK_PORT="${VSOCK_PORT:-9967}"           # mesma porta do monitor.sh
HOST_CID="${HOST_CID:-2}"                  # CID do host (sempre 2 no KVM/QEMU)

# Os 5 .exe a testar — coloque os arquivos em EXE_DIR antes de rodar
EXE_DIR="${EXE_DIR:-$HOME/wine67ci/exes}"

# Diretório de trabalho temporário
WORK_DIR="${WORK_DIR:-/tmp/wine67ci}"

WINE67_CACHE="$HOME/.cache/wine67"
WINE67_BIN="$WINE67_CACHE/bin/wine"
# ══════════════════════════════════════════════════════════════════

mkdir -p "$WORK_DIR" "$EXE_DIR"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "[ERRO] $*" >&2; exit 1; }

# ── Verifica dependências ─────────────────────────────────────────
for cmd in socat bash; do
    command -v "$cmd" &>/dev/null || die "$cmd não encontrado."
done

# ── Protocolo vsock (mesmo do monitor.sh) ────────────────────────
vsock_recv() {
    local timeout="${1:-60}"
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

vsock_send() {
    local content="$1"
    local size="${#content}"
    local header
    header=$(printf '%010d' "$size")
    printf '%s%s' "$header" "$content" \
        | socat - "VSOCK-CONNECT:${HOST_CID}:${VSOCK_PORT}" \
        || log "Falha ao enviar dados via vsock"
}

# ── Roda um .exe com wine e coleta resultado ──────────────────────
test_exe() {
    local exe="$1"
    local name
    name=$(basename "$exe")
    local out_file="$WORK_DIR/out_${name}.log"
    local status="UNKNOWN"
    local exit_code=0

    log "  Testando: $name ..."

    # Timeout de 30s por exe — se crashar ou demorar demais, mata
    if timeout 30s "$WINE67_BIN" "$exe" > "$out_file" 2>&1; then
        exit_code=$?
        status="OK"
    else
        exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            status="TIMEOUT"
        else
            status="CRASH (exit $exit_code)"
        fi
    fi

    # Captura as últimas linhas de saída como evidência
    local tail_output
    tail_output=$(tail -10 "$out_file" 2>/dev/null || echo "(sem saída)")

    printf '[%s] %s\n' "$status" "$name"
    printf '  Saída (últimas linhas):\n'
    printf '  %s\n' "$tail_output"
    printf '\n'
}

# ══════════════════════════════════════════════════════════════════
# LOOP PRINCIPAL
# ══════════════════════════════════════════════════════════════════
log "=== wine67ci agente iniciado (escutando vsock porta $VSOCK_PORT) ==="

while true; do

    # ── Etapa 1: recebe o wine67.sh ───────────────────────────────
    log "Aguardando wine67.sh do servidor ..."
    SCRIPT_CONTENT=$(vsock_recv 3600)   # espera até 1h por um novo deploy

    if [[ -z "$SCRIPT_CONTENT" ]]; then
        log "Timeout aguardando script. Reiniciando escuta ..."
        continue
    fi

    WINE67_SCRIPT="$WORK_DIR/wine67.sh"
    printf '%s' "$SCRIPT_CONTENT" > "$WINE67_SCRIPT"
    chmod +x "$WINE67_SCRIPT"
    log "wine67.sh recebido (${#SCRIPT_CONTENT} bytes)."

    # ── Etapa 2: recebe sinal RUN ─────────────────────────────────
    log "Aguardando sinal RUN ..."
    SIGNAL=$(vsock_recv 30)

    if [[ "$SIGNAL" != RUN:* ]]; then
        log "Sinal inesperado: '$SIGNAL'. Abortando ciclo."
        continue
    fi

    COMMIT_SHA="${SIGNAL#RUN:}"
    log "▶ Sinal RUN recebido (commit $COMMIT_SHA). Iniciando testes ..."

    # ── Etapa 3: instala/atualiza o wine67.sh ────────────────────
    REPORT=""
    REPORT+="=== wine67ci — Relatório da VM ===\n"
    REPORT+="Commit  : $COMMIT_SHA\n"
    REPORT+="Data    : $(date '+%d/%m/%Y %H:%M:%S')\n"
    REPORT+="Host    : $(hostname)\n"
    REPORT+="Distro  : $(grep '^PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'desconhecida')\n"
    REPORT+="==================================\n\n"

    log "Rodando wine67.sh --setup-only ..."
    SETUP_OUT=$(WINE67_CI=1 bash "$WINE67_SCRIPT" --setup-only 2>&1 || true)
    REPORT+="── Instalação do Wine ──\n$SETUP_OUT\n\n"

    # Verifica se o binário wine está disponível após instalação
    if [[ ! -x "$WINE67_BIN" ]]; then
        REPORT+="[ERRO] Binário wine não encontrado em $WINE67_BIN após instalação.\n"
        REPORT+="       Testes de .exe abortados.\n"
        log "❌ wine não instalado. Enviando relatório de falha ..."
        vsock_send "$(printf '%b' "$REPORT")"
        continue
    fi

    REPORT+="[OK] Wine instalado: $("$WINE67_BIN" --version 2>/dev/null || echo 'versão desconhecida')\n\n"

    # ── Etapa 4: testa os 5 .exe ─────────────────────────────────
    REPORT+="── Testes dos .exe ──\n"

    mapfile -t EXE_LIST < <(find "$EXE_DIR" -maxdepth 1 -name '*.exe' | sort | head -5)

    if [[ ${#EXE_LIST[@]} -eq 0 ]]; then
        REPORT+="[AVISO] Nenhum .exe encontrado em $EXE_DIR\n"
        REPORT+="        Coloque os arquivos .exe em $EXE_DIR antes de rodar.\n"
        log "⚠ Nenhum .exe encontrado."
    else
        PASS=0
        FAIL=0
        for exe in "${EXE_LIST[@]}"; do
            result=$(test_exe "$exe")
            REPORT+="$result\n"
            if echo "$result" | grep -q '^\[OK\]'; then
                ((PASS++)) || true
            else
                ((FAIL++)) || true
            fi
        done
        REPORT+="\n── Resumo ──\n"
        REPORT+="PASS : $PASS\n"
        REPORT+="FAIL : $FAIL\n"
        REPORT+="TOTAL: $((PASS + FAIL))\n"
        if [[ $FAIL -eq 0 ]]; then
            REPORT+="STATUS: ✅ TUDO OK\n"
        else
            REPORT+="STATUS: ❌ $FAIL FALHA(S) DETECTADA(S)\n"
        fi
    fi

    # ── Etapa 5: envia relatório de volta ─────────────────────────
    log "Enviando relatório ao servidor ..."
    vsock_send "$(printf '%b' "$REPORT")"
    log "✅ Relatório enviado. Aguardando próximo ciclo ..."

done
