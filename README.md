# wine67ci

Pipeline de CI leve para o **wine67.sh** em 2 scripts comunicados via **vsock**.

```
monitor.sh  (servidor/host)          agente.sh  (VM/guest)
──────────────────────────           ───────────────────────
polling GitHub a cada X min    →     recebe wine67.sh
detecta commit novo            →     recebe sinal RUN
envia wine67.sh via vsock      →     instala wine67.sh
envia sinal RUN                →     roda 5 .exe, coleta logs
aguarda relatório              ←     envia relatório via vsock
analisa com Groq
salva log + envia email
```

---

## Pré-requisitos

### Servidor (host)
- `socat` — `sudo apt install socat` ou `sudo dnf install socat`
- `curl`, `python3`
- Módulo `vhost_vsock` carregado: `sudo modprobe vhost_vsock`

### VM (guest)
- `socat`
- `bash`
- Os 5 arquivos `.exe` a testar em `~/wine67ci/exes/`

---

## Configuração

Todas as variáveis ficam no topo de cada script ou podem ser exportadas antes de rodar.

### monitor.sh

| Variável | Padrão | Descrição |
|---|---|---|
| `GITHUB_REPO` | `gabrieldeisrael/wine67` | user/repo no GitHub |
| `GITHUB_BRANCH` | `main` | branch a monitorar |
| `GITHUB_FILE` | `wine67.sh` | arquivo a baixar |
| `POLL_INTERVAL` | `300` | segundos entre checks |
| `VSOCK_PORT` | `9967` | porta vsock |
| `VM_CID` | `3` | CID da VM |
| `GROQ_API_KEY` | — | chave do Groq Cloud |
| `GMAIL_USER` | — | remetente Gmail |
| `GMAIL_APP_PASSWORD` | — | App Password Gmail |
| `EMAIL_DESTINO` | — | destinatário do relatório |
| `LOG_DIR` | `~/.local/share/wine67ci/logs` | onde salvar os logs |

### agente.sh

| Variável | Padrão | Descrição |
|---|---|---|
| `VSOCK_PORT` | `9967` | mesma porta do monitor.sh |
| `HOST_CID` | `2` | CID do host (sempre 2 no KVM) |
| `EXE_DIR` | `~/wine67ci/exes` | pasta com os 5 .exe de teste |
| `WORK_DIR` | `/tmp/wine67ci` | diretório temporário |

---

## Setup rápido

### 1. Habilitar vsock no host

```bash
sudo modprobe vhost_vsock
# Para persistir no boot:
echo 'vhost_vsock' | sudo tee /etc/modules-load.d/vsock.conf
```

### 2. Descobrir o CID da VM

```bash
# No host, após a VM estar ligada:
cat /sys/bus/vmbus/devices/*/id 2>/dev/null   # Hyper-V
# ou
virsh dumpxml <nome-da-vm> | grep vsock       # KVM/libvirt
```

Se estiver usando QEMU direto, adicione ao comando de boot da VM:
```
-device vhost-vsock-pci,guest-cid=3
```
E configure `VM_CID=3` no monitor.sh.

### 3. Coloque os .exe na VM

```bash
mkdir -p ~/wine67ci/exes
# copie seus 5 arquivos .exe para ~/wine67ci/exes/
```

### 4. Configure as variáveis e rode

**Na VM (deixe rodando em background ou screen/tmux):**
```bash
chmod +x agente.sh
VSOCK_PORT=9967 bash agente.sh
```

**No servidor:**
```bash
chmod +x monitor.sh
export GITHUB_REPO="gabrieldeisrael/wine67"
export GROQ_API_KEY="gsk_..."
export GMAIL_USER="seu@gmail.com"
export GMAIL_APP_PASSWORD="sua_app_password"
export EMAIL_DESTINO="seu@gmail.com"
export VM_CID=3
bash monitor.sh
```

### 5. Rodar como serviço (opcional)

```bash
# Cria serviços systemd para ambos
# No host:
sudo systemd-run --unit=wine67ci-monitor \
    --same-dir --uid=$(id -u) \
    bash /caminho/para/monitor.sh

# Na VM:
sudo systemd-run --unit=wine67ci-agente \
    --same-dir --uid=$(id -u) \
    bash /caminho/para/agente.sh
```

---

## Protocolo vsock

Mensagens usam um header fixo de **10 dígitos** com o tamanho do payload:

```
┌──────────────┬─────────────────────────┐
│  0000001234  │  <conteúdo da mensagem> │
│  (10 bytes)  │  (N bytes)              │
└──────────────┴─────────────────────────┘
```

Sinais trocados:
- `RUN:<sha8>` — servidor → VM, instrui a iniciar os testes
- relatório completo em texto — VM → servidor

---

## Logs

Salvos em `~/.local/share/wine67ci/logs/` no servidor:
```
relatorio_2026-06-29_14-30-00.txt   ← análise do Groq + log bruto
```
