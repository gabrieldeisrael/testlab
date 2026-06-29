#!/usr/bin/env bash
# agente.sh — roda na VM (guest)
# Fluxo:
#   1. Escuta vsock, recebe wine67.sh do servidor
#   2. Recebe sinal RUN:<sha>
#   3. Para cada .exe em EXE_DIR:
#      - copia wine67.sh + .exe para um dir isolado
#      - wine67.sh faz find("$SCRIPT_DIR", "*.exe") → acha exatamente 1 → menu lista [1]
#      - alimenta "1\n" via pipe para selecionar automaticamente
#      - captura saída + exit code + duração
#   4. Monta relatório e envia de volta via vsock

set -euo pipefail

# ══════════════════════════════════════════════════════════════════
# CONFIGURAÇÃO
# ══════════════════════════════════════════════════════════════════
VSOCK_PORT="${VSOCK_PORT:-9967}"
HOST_CID="${HOST_CID:-2}"                  # CID do host (sempre 2 no KVM/QEMU)

# Pasta com os .exe a testar — coloque os arquivos aqui antes de rodar
EXE_DIR="${EXE_DIR:-$HOME/wine67ci/exes}"

# Dir de trabalho temporário (recriado a cada ciclo)
WORK_BASE="${WORK_BASE:-/tmp/wine67ci}"

# Timeout por exe: inclui wineboot (1ª vez ~60s) + execução do .exe
# Na primeira execução wine67.sh também baixa o Wine (~500MB) se não estiver cacheado.
# O download só acontece uma vez pois vai para ~/.cache/wine67 que persiste entre testes.
EXE_TIMEOUT="${EXE_TIMEOUT:-180}"
# ══════════════════════════════════════════════════════════════════

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[ERRO] $*" >&2; exit 1; }

for cmd in socat bash timeout; do
    command -v "$cmd" &>/dev/null || die "$cmd não encontrado."
done

# ── Protocolo vsock: header 10 dígitos + payload ─────────────────
vsock_recv() {
    local tout="${1:-3600}"
    socat -T "$tout" "VSOCK-LISTEN:${VSOCK_PORT},reuseaddr" - 2>/dev/null | {
        IFS= read -r -n 10 header
        local size="${header// /}"
        [[ -z "$size" || ! "$size" =~ ^[0-9]+$ ]] && return
        dd bs=1 count="$size" 2>/dev/null
    }
}

vsock_send() {
    local content="$1"
    printf '%010d%s' "${#content}" "$content" \
        | socat - "VSOCK-CONNECT:${HOST_CID}:${VSOCK_PORT}" \
        || log "⚠ Falha ao enviar relatório via vsock"
}

# ── Roda um único .exe via wine67.sh em modo não-interativo ──────
#
# wine67.sh é interativo por design (menu, clear, spinner, read).
# Estratégia para CI:
#
#   1. Dir isolado: copiamos wine67.sh + APENAS 1 .exe para um dir temporário.
#      wine67.sh faz:  find "$SCRIPT_DIR" -name "*.exe"
#      Como há só 1 .exe, o menu lista exatamente [1] esse arquivo.
#
#   2. Alimentamos "1\n" via echo para o read do menu selecionar automaticamente.
#
#   3. TERM=dumb suprime o clear e faz o spinner não riscar o terminal.
#
#   4. WINE67_CI=1 é exportado caso o script queira detectar modo CI no futuro.
#
#   5. O cache do Wine (~/.cache/wine67) é compartilhado — o download/extração
#      só ocorre na primeira execução, as demais são instantâneas.
#
#   6. O prefix por jogo (WINEPREFIX=~/.cache/wine67/prefixes/<nome>) também
#      persiste entre ciclos, então o wineboot só roda uma vez por .exe novo.

run_exe() {
    local exe_path="$1"
    local exe_name
    exe_name=$(basename "$exe_path")
    local run_dir="$WORK_BASE/run_${exe_name%.exe}"

    # Limpa dir isolado do ciclo anterior (se houver)
    rm -rf "$run_dir"
    mkdir -p "$run_dir"

    # wine67.sh + somente este .exe no dir → menu vai listar [1] ele
    cp "$WORK_BASE/wine67.sh" "$run_dir/wine67.sh"
    chmod +x "$run_dir/wine67.sh"
    cp "$exe_path" "$run_dir/$exe_name"

    local out_file="$run_dir/output.log"
    local start_ts exit_code elapsed

    start_ts=$(date +%s)

    # echo "1" → seleciona item [1] do menu interativo do wine67.sh
    # TERM=dumb  → suprime clear + spinner (sem sequências de escape)
    # WINE67_CI=1 → flag para o script detectar modo CI (futuro)
    # DISPLAY     → necessário para Wine inicializar janela; Xvfb na porta :99 é ideal
    #               se não houver display, o .exe vai crashar imediatamente — isso é
    #               informação válida: registramos como CRASH(no display)
    if timeout "$EXE_TIMEOUT" bash -c \
        "echo '1' | TERM=dumb WINE67_CI=1 DISPLAY=${DISPLAY:-:0} bash '$run_dir/wine67.sh'" \
        > "$out_file" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi

    elapsed=$(( $(date +%s) - start_ts ))

    # Remove códigos ANSI e \r que possam ter escapado do TERM=dumb
    sed -i $'s/\x1b\\[[0-9;]*m//g; s/\r//g' "$out_file" 2>/dev/null || true

    # Classifica resultado
    local status
    if   [[ $exit_code -eq 124 ]]; then
        status="TIMEOUT (>${EXE_TIMEOUT}s)"
    elif [[ $exit_code -eq 0 ]]; then
        status="OK"
    else
        # Captura última mensagem de erro relevante para o status
        local last_err
        last_err=$(grep -iE '(erro|error|❌|falha|fault|crash|segfault)' "$out_file" \
                   | tail -1 | sed 's/^[[:space:]]*//' || true)
        status="CRASH (exit ${exit_code}${last_err:+ — ${last_err:0:60}})"
    fi

    # Evidência: últimas 25 linhas do log
    local tail_out
    tail_out=$(tail -25 "$out_file" 2>/dev/null || echo "(sem saída)")

    # Imprime resultado estruturado
    printf '[%s] %s  (%ds)\n' "$status" "$exe_name" "$elapsed"
    printf '  Log (últimas linhas):\n'
    while IFS= read -r line; do
        printf '    %s\n' "$line"
    done <<< "$tail_out"
    printf '\n'

    # Limpa dir isolado (o cache do Wine em ~/.cache/wine67 permanece)
    rm -rf "$run_dir"

    return $exit_code
}

# ══════════════════════════════════════════════════════════════════
# LOOP PRINCIPAL
# ══════════════════════════════════════════════════════════════════
log "=== wine67ci agente iniciado (vsock porta $VSOCK_PORT) ==="
log "    EXE_DIR    : $EXE_DIR"
log "    EXE_TIMEOUT: ${EXE_TIMEOUT}s por exe"
log "    HOST_CID   : $HOST_CID"
mkdir -p "$EXE_DIR" "$WORK_BASE"

while true; do

    # ── 1. Recebe wine67.sh ───────────────────────────────────────
    log "Aguardando wine67.sh do servidor (host CID $HOST_CID → porta $VSOCK_PORT) ..."
    SCRIPT_CONTENT=$(vsock_recv 3600)   # espera até 1h

    if [[ -z "$SCRIPT_CONTENT" ]]; then
        log "⚠ Timeout/sem dados. Reiniciando escuta ..."
        continue
    fi

    # Salva o script recebido
    printf '%s' "$SCRIPT_CONTENT" > "$WORK_BASE/wine67.sh"
    chmod +x "$WORK_BASE/wine67.sh"
    log "wine67.sh recebido (${#SCRIPT_CONTENT} bytes)."

    # Extrai versão do Wine que o script vai baixar (para o relatório)
    WINE_VER=$(grep -o 'wine-[0-9][0-9.]*' "$WORK_BASE/wine67.sh" | head -1 || echo "desconhecida")

    # ── 2. Recebe sinal RUN ───────────────────────────────────────
    log "Aguardando sinal RUN ..."
    SIGNAL=$(vsock_recv 30)

    if [[ "$SIGNAL" != RUN:* ]]; then
        log "⚠ Sinal inesperado: '$SIGNAL'. Abortando ciclo."
        continue
    fi

    COMMIT_SHA="${SIGNAL#RUN:}"
    log "▶ RUN recebido (commit $COMMIT_SHA). Iniciando testes ..."

    # ── 3. Lista os .exe (máx 5) ─────────────────────────────────
    mapfile -t EXE_LIST < <(find "$EXE_DIR" -maxdepth 1 -name '*.exe' | sort | head -5)

    # ── 4. Cabeçalho do relatório ─────────────────────────────────
    REPORT=""
    REPORT+="=== wine67ci — Relatório da VM ===\n"
    REPORT+="Commit      : $COMMIT_SHA\n"
    REPORT+="Data        : $(date '+%d/%m/%Y %H:%M:%S')\n"
    REPORT+="VM hostname : $(hostname)\n"
    REPORT+="Distro      : $(grep '^PRETTY_NAME' /etc/os-release 2>/dev/null \
                | cut -d= -f2 | tr -d '"' || echo 'desconhecida')\n"
    REPORT+="Wine versão : $WINE_VER (fallback do script)\n"
    REPORT+="Cache Wine  : ${HOME}/.cache/wine67\n"
    REPORT+="EXEs testados: ${#EXE_LIST[@]}\n"
    REPORT+="==================================\n\n"

    if [[ ${#EXE_LIST[@]} -eq 0 ]]; then
        REPORT+="[AVISO] Nenhum .exe encontrado em $EXE_DIR\n"
        REPORT+="        Coloque os arquivos .exe em $EXE_DIR e reinicie o agente.\n"
        log "⚠ Nenhum .exe em $EXE_DIR"
        vsock_send "$(printf '%b' "$REPORT")"
        continue
    fi

    # ── 5. Executa cada .exe ──────────────────────────────────────
    REPORT+="── Testes dos .exe ──\n\n"
    PASS=0; FAIL=0; TIMEOUT_COUNT=0

    for exe in "${EXE_LIST[@]}"; do
        log "  → $(basename "$exe")"
        result=$(run_exe "$exe" 2>&1) && rc=0 || rc=$?
        REPORT+="$result\n"

        if   [[ $rc -eq 0   ]]; then ((PASS++))         || true
        elif [[ $rc -eq 124 ]]; then ((TIMEOUT_COUNT++)) || true; ((FAIL++)) || true
        else                         ((FAIL++))          || true
        fi
    done

    # ── 6. Resumo ─────────────────────────────────────────────────
    REPORT+="── Resumo ──\n"
    REPORT+="PASS    : $PASS / $((PASS + FAIL))\n"
    REPORT+="FAIL    : $FAIL / $((PASS + FAIL))\n"
    REPORT+="TIMEOUT : $TIMEOUT_COUNT\n"
    if [[ $FAIL -eq 0 ]]; then
        REPORT+="STATUS  : ✅ TUDO OK\n"
    else
        REPORT+="STATUS  : ❌ $FAIL FALHA(S) DETECTADA(S)\n"
    fi

    # ── 7. Versão real do Wine (se já instalado) ──────────────────
    WINE_BIN="$HOME/.cache/wine67/bin/wine"
    if [[ -x "$WINE_BIN" ]]; then
        REAL_VER=$("$WINE_BIN" --version 2>/dev/null || echo "erro ao obter versão")
        REPORT+="\nWine instalado: $REAL_VER\n"
    fi

    # ── 8. Envia relatório ────────────────────────────────────────
    log "Enviando relatório (PASS=$PASS FAIL=$FAIL TIMEOUT=$TIMEOUT_COUNT) ..."
    vsock_send "$(printf '%b' "$REPORT")"
    log "✅ Relatório enviado. Aguardando próximo ciclo ..."

done
