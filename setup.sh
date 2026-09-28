#!/bin/bash
#
# setup.sh — Remnawave Node Multi-Protocol Setup v3.3
# by Rezzosoft KVN | https://rezzosoft.ru/converter.html
#
set -uo pipefail

show_logo() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║     ██████╗ ███████╗███╗   ███╗███╗   ██╗ █████╗ ██╗    ██╗      ║
║     ██╔══██╗██╔════╝████╗ ████║████╗  ██║██╔══██╗██║    ██║      ║
║     ██████╔╝█████╗  ██╔████╔██║██╔██╗ ██║███████║██║ █╗ ██║      ║
║     ██╔══██╗██╔══╝  ██║╚██╔╝██║██║╚██╗██║██╔══██║██║███╗██║      ║
║     ██║  ██║███████╗██║ ╚═╝ ██║██║ ╚████║██║  ██║╚███╔███╔╝      ║
║     ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚══╝╚══╝       ║
║                                                                  ║
║           Remnawave Node Multi-Protocol Setup v3.3               ║
║                      by Rezzosoft KVN                            ║
║                                                                  ║
║   Конвертер конфигов: https://rezzosoft.ru/converter.html        ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
EOF
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
log_info() { echo -e "${BLUE}[•]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

fatal() {
    log_error "$1"
    [[ -n "${2:-}" ]] && log_warn "$2"
    exit 1
}

preflight_checks() {
    log_info "Запуск проверок окружения..."
    echo ""

    [[ "$EUID" -ne 0 ]] && fatal "Скрипт требует прав root" "Запустите: sudo bash $0"
    log_ok "Права root подтверждены"

    command -v docker &>/dev/null || fatal "Docker CLI не найден" "Установите Docker"
    log_ok "Docker CLI найден"

    docker info &>/dev/null || fatal "Docker daemon не запущен" "Выполните: systemctl start docker"
    log_ok "Docker daemon работает"

    docker inspect remnanode &>/dev/null || fatal "Контейнер 'remnanode' не найден" "Установите панель Remnawave"

    local container_status
    container_status=$(docker inspect remnanode --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    [[ "$container_status" != "running" ]] && fatal "Контейнер 'remnanode' не запущен (статус: $container_status)"
    log_ok "Контейнер remnanode запущен"

    # Проверка NetworkMode
    local network_mode
    network_mode=$(docker inspect remnanode --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || echo "unknown")
    
    # КРИТИЧЕСКАЯ ПРОВЕРКА: Xray реально слушает 443/tcp
    # Для host mode проверяем на хосте, для bridge - внутри контейнера
    if [[ "$network_mode" == "host" ]]; then
        # Host mode: порты контейнера видны на хосте, внутри ss нет
        if ! ss -ltnp 2>/dev/null | grep -q ':443 '; then
            fatal "Порт 443/tcp не слушается" "Xray упал или не запустился. Логи: docker logs remnanode"
        fi
        log_ok "Xray слушает порт 443/tcp (проверено на хосте, network mode: host)"
    else
        # Bridge mode (теоретический): проверяем внутри контейнера
        if docker exec remnanode command -v ss &>/dev/null; then
            if ! docker exec remnanode ss -ltnp 2>/dev/null | grep -q ':443 '; then
                fatal "Порт 443/tcp не слушается внутри контейнера" "Логи: docker logs remnanode"
            fi
            log_ok "Xray слушает порт 443/tcp (проверено внутри контейнера)"
        else
            # Если ss нет внутри — проверяем на хосте по маппингу
            if ! ss -ltnp 2>/dev/null | grep -q ':443 '; then
                fatal "Порт 443/tcp не слушается" "Логи: docker logs remnanode"
            fi
            log_ok "Xray слушает порт 443/tcp (fallback проверка на хосте)"
        fi
    fi

    docker inspect remnanode --format '{{json .Mounts}}' 2>/dev/null | grep -q '/dev/shm' || \
        fatal "/dev/shm не примонтирован" "Добавьте в docker-compose.yml: - /dev/shm:/dev/shm"
    log_ok "/dev/shm доступен"

    # ─── ПОИСК СЕРТИФИКАТОВ: /root/cert/ → /etc/letsencrypt/live/ ───
    local cert_root="/root/cert"
    local le_root="/etc/letsencrypt/live"

    CERT_DIR=""
    DOMAIN=""

    # Приоритет 1: /root/cert/<домен>/
    if [[ -d "$cert_root" ]]; then
        DOMAIN=$(find "$cert_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -n1)
        if [[ -n "$DOMAIN" && -f "$cert_root/$DOMAIN/fullchain.pem" && -f "$cert_root/$DOMAIN/privkey.pem" ]]; then
            CERT_DIR="$cert_root/$DOMAIN"
            log_ok "Сертификаты найдены в $cert_root для: $DOMAIN"
        fi
    fi

    # Приоритет 2: /etc/letsencrypt/live/<домен>/
    if [[ -z "$CERT_DIR" && -d "$le_root" ]]; then
        DOMAIN=$(find "$le_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -v README | head -n1)
        if [[ -n "$DOMAIN" && -f "$le_root/$DOMAIN/fullchain.pem" && -f "$le_root/$DOMAIN/privkey.pem" ]]; then
            CERT_DIR="$le_root/$DOMAIN"
            log_ok "Сертификаты найдены в $le_root для: $DOMAIN"
        fi
    fi

    [[ -z "$CERT_DIR" ]] && fatal "Сертификаты не найдены" \
        "Проверьте $cert_root или $le_root (нужны fullchain.pem и privkey.pem)"

    CERT_PATH="$CERT_DIR/fullchain.pem"
    KEY_PATH="$CERT_DIR/privkey.pem"

    [[ ! -f "$CERT_PATH" ]] && fatal "Файл сертификата не найден: $CERT_PATH"
    [[ ! -f "$KEY_PATH" ]] && fatal "Файл ключа не найден: $KEY_PATH"
    # ─── КОНЕЦ БЛОКА ПОИСКА ───

    if command -v ufw &>/dev/null; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -n1 | awk '{print $2}')
        if [[ "$ufw_status" == "active" ]]; then
            log_ok "UFW активен"
            UFW_ACTIVE=true
        else
            log_warn "UFW не активен. Откройте порты вручную"
            UFW_ACTIVE=false
        fi
    else
        log_warn "UFW не установлен"
        UFW_ACTIVE=false
    fi
    echo ""
}

is_port_open_in_ufw() {
    local port="$1"
    local proto="${2:-tcp}"
    ufw status 2>/dev/null | grep -qE "^${port}/${proto}\s+ALLOW"
}

open_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local desc="$3"

    [[ "$UFW_ACTIVE" != "true" ]] && return 0

    if is_port_open_in_ufw "$port" "$proto"; then
        log_ok "Порт $port/$proto уже открыт ($desc)"
        return 0
    fi

    if ufw allow "$port/$proto" &>/dev/null; then
        log_ok "Порт $port/$proto открыт ($desc)"
        return 0
    else
        log_error "Не удалось открыть $port/$proto"
        return 1
    fi
}

sync_certs_to_shm() {
    local shm_cert="/dev/shm/hysteria_cert.pem"
    local shm_key="/dev/shm/hysteria_key.pem"

    if [[ ! -f "$shm_cert" ]] || [[ ! -f "$shm_key" ]] || \
       ! cmp -s "$CERT_PATH" "$shm_cert" || ! cmp -s "$KEY_PATH" "$shm_key"; then
        cp -f "$CERT_PATH" "$shm_cert"
        cp -f "$KEY_PATH" "$shm_key"
        chmod 644 /dev/shm/hysteria_*.pem
        log_ok "Сертификаты синхронизированы в /dev/shm"
        return 0
    else
        log_ok "Сертификаты в /dev/shm актуальны"
        return 1
    fi
}

setup_cert_cron() {
    local cron_reboot="@reboot cp $CERT_PATH /dev/shm/hysteria_cert.pem && cp $KEY_PATH /dev/shm/hysteria_key.pem && chmod 644 /dev/shm/*.pem && sleep 15 && docker restart remnanode"
    local cron_daily="0 4 * * * cp $CERT_PATH /dev/shm/hysteria_cert.pem && cp $KEY_PATH /dev/shm/hysteria_key.pem && chmod 644 /dev/shm/*.pem && docker restart remnanode"

    if crontab -l 2>/dev/null | grep -q "hysteria_cert.pem"; then
        log_ok "Cron уже настроен"
    else
        (crontab -l 2>/dev/null; echo "$cron_reboot"; echo "$cron_daily") | crontab -
        log_ok "Cron для сертификатов добавлен"
    fi
}

show_menu() {
    echo ""
    log_info "Выберите дополнительные протоколы:"
    echo ""
    echo -e "${BLUE}  [1]${NC} Hysteria2 (QUIC) — 443/udp"
    echo -e "${BLUE}  [2]${NC} VLESS gRPC + Reality — 8443/tcp"
    echo -e "${BLUE}  [3]${NC} VLESS XHTTP + Reality — 4443/tcp"
    echo -e "${BLUE}  [4]${NC} Все три (1+2+3)"
    echo ""
    echo -n "Ваш выбор (1-4): "
    read -r user_input

    SELECTED=()
    
    [[ ! "$user_input" =~ ^[1-4]([[:space:]]+[1-4])*$ ]] && \
        fatal "Неверный формат" "Используйте цифры 1-4. Пример: 1 2"

    for num in $user_input; do
        case "$num" in
            1) [[ ! " ${SELECTED[*]} " =~ " hy2 " ]] && SELECTED+=("hy2") ;;
            2) [[ ! " ${SELECTED[*]} " =~ " grpc " ]] && SELECTED+=("grpc") ;;
            3) [[ ! " ${SELECTED[*]} " =~ " xhttp " ]] && SELECTED+=("xhttp") ;;
            4) SELECTED=("hy2" "grpc" "xhttp"); break ;;
        esac
    done

    log_ok "Выбрано: ${SELECTED[*]}"
    echo ""
}

apply_config() {
    log_info "Применение конфигурации..."
    echo ""

    local certs_changed=false

    for proto in "${SELECTED[@]}"; do
        case "$proto" in
            hy2)
                open_port 443 "udp" "Hysteria2"
                sync_certs_to_shm && certs_changed=true
                setup_cert_cron
                ;;
            grpc)
                open_port 8443 "tcp" "VLESS gRPC"
                ;;
            xhttp)
                open_port 4443 "tcp" "VLESS XHTTP"
                ;;
        esac
    done

    if [[ "$certs_changed" == "true" ]]; then
        log_info "Перезапуск контейнера (изменены сертификаты)..."
        docker restart remnanode &>/dev/null && sleep 3 && log_ok "Контейнер перезапущен"
    else
        log_ok "Перезапуск не требуется"
    fi
    echo ""
}

finalize() {
    echo "═══════════════════════════════════════════════════════════"
    echo -e "${GREEN}✓ Настройка завершена!${NC}"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo -e "${BLUE}📋 Сводка:${NC}"
    echo "   • Домен: $DOMAIN"
    echo "   • Базовый: 443/tcp — VLESS TCP Reality"
    
    for proto in "${SELECTED[@]}"; do
        case "$proto" in
            hy2)   echo "   • 443/udp — Hysteria2" ;;
            grpc)  echo "   • 8443/tcp — VLESS gRPC" ;;
            xhttp) echo "   • 4443/tcp — VLESS XHTTP" ;;
        esac
    done

    echo ""
    echo -e "${BLUE}🔧 Следующие шаги:${NC}"
    echo "   1. Откройте панель Remnawave"
    echo "   2. Используйте конвертер:"
    echo -e "      ${BLUE}https://rezzosoft.ru/converter.html${NC}"
    echo "   3. Вставьте конфиг в профиль ноды"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
}

main() {
    clear
    show_logo
    echo ""
    preflight_checks
    show_menu
    apply_config
    finalize
}

main "$@"
