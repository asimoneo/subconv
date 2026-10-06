#!/bin/sh
# =====================================================================
# Subconv Installer & Updater (v0.3.16)
# =====================================================================
# Автоматический скрипт установки и обновления плагина Subconv для OpenWrt.
# Поддерживает архитектуры: x86_64, aarch64, arm, mips.
# =====================================================================

VERSION="0.3.16"

# Цвета для вывода в терминал
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Очистка экрана и приветствие
clear
echo "======================================================"
echo "          Subconv Installer & Updater v${VERSION}        "
echo "======================================================"
echo ""

# Проверка режима запуска (через аргументы командной строки)
# Пример: sh install.sh -s 1 (тихий режим, обновление)
# Пример: sh install.sh -s 2 (тихий режим, удаление)
SILENT_MODE=0
ACTION_CHOICE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -s|--silent)
            SILENT_MODE=1
            ACTION_CHOICE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [ "$SILENT_MODE" -eq 0 ]; then
    echo "Выберите действие:"
    echo "1) Установить / Обновить Subconv"
    echo "2) Полностью удалить Subconv"
    echo "0) Выход"
    echo ""
    printf "Ваш выбор [1]: "
    read -r user_choice
    if [ -z "$user_choice" ]; then
        ACTION_CHOICE=1
    else
        ACTION_CHOICE="$user_choice"
    fi
fi

if [ "$ACTION_CHOICE" -eq 0 ]; then
    echo "Отмена операции."
    exit 0
fi

if [ "$ACTION_CHOICE" -eq 2 ]; then
    echo ""
    echo "🗑️ Удаление Subconv..."
    
    # Удаление созданных файлов подписок
    if [ -f /etc/config/subconv ]; then
        SUBS=$(uci show subconv | grep "=subscription" | cut -d'.' -f2 | cut -d'=' -f1)
        for sub in $SUBS; do
            if [ -n "$sub" ]; then
                rm -f "/www/${sub}.txt"
            fi
        done
    fi

    rm -f /usr/libexec/subconv-update.sh
    rm -f /usr/libexec/subconv-cron.sh
    rm -f /usr/libexec/happ-decrypt
    rm -f /usr/libexec/happ-decrypt.py
    rm -f /usr/lib/lua/luci/controller/subconv.lua
    rm -f /usr/lib/lua/luci/model/cbi/subconv.lua
    rm -f /usr/share/luci/menu.d/subconv.json
    rm -f /usr/share/rpcd/acl.d/subconv.json
    rm -f /etc/config/subconv
    rm -f /www/subconv_debug.txt
    rm -f /tmp/subconv_ver_cache
    rm -f /tmp/subconv_status.json
    rm -f /tmp/subconv.lock
    
    if [ -f /etc/crontabs/root ]; then
        sed -i '/subconv-update.sh/d' /etc/crontabs/root
        /etc/init.d/cron restart
    fi
    
    rm -rf /tmp/luci-* /tmp/rpcd-* /tmp/state/*
    /etc/init.d/rpcd restart
    
    echo "✅ Плагин полностью удален!"
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "📦 Установка зависимости: curl..."
    if which apk >/dev/null 2>&1; then
        apk add curl
    else
        opkg update && opkg install curl
    fi
fi

if which apk >/dev/null 2>&1; then
    if ! apk info -e luci-compat >/dev/null 2>&1; then
        echo "📦 Установка зависимости: luci-compat..."
        apk add luci-compat
    fi
else
    if ! opkg list-installed | grep -q "^luci-compat "; then
        echo "📦 Установка зависимости: luci-compat..."
        opkg update && opkg install luci-compat
    fi
fi

echo "🚀 Установка / Обновление Subconv v${VERSION}..."

mkdir -p /usr/libexec
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/lib/lua/luci/model/cbi
mkdir -p /usr/share/luci/menu.d
mkdir -p /usr/share/rpcd/acl.d

cat << 'EOF' > /usr/libexec/subconv-update.sh
#!/usr/bin/lua
-- =====================================================================
-- Скрипт обновления и конвертации подписок (subconv-update.sh)
-- =====================================================================
-- Этот скрипт вызывается как вручную из LuCI, так и по расписанию Cron.
-- Он скачивает подписку, дешифрует happ://crypt ссылки, проверяет
-- полученные данные (Base64, JSON, YAML) и сохраняет список ссылок vless://.

local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local nixio = require "nixio"
local sys = require "luci.sys"

-- ID подписки передается первым аргументом командной строки
local sub_id = arg[1]
local debug_file = "/www/subconv_debug.txt"

-- ==========================================
-- Вспомогательные функции
-- ==========================================

-- Запись в журнал отладки
local function log(msg)
    local f_dbg = io.open(debug_file, "a")
    if f_dbg then
        -- Форматируем строку: [Дата] [ID подписки] Сообщение
        f_dbg:write(os.date("%Y-%m-%d %H:%M:%S") .. " [" .. (sub_id or "NONE") .. "] " .. msg .. "\n")
        f_dbg:close()
    end
end

-- Безопасное маскирование приватных URL и токенов (стандарт GitHub / AWS)
local function mask_url(u)
    if not u or u == "" then return "" end
    if #u <= 18 then return u end
    local tail = u:sub(-4)
    local body = u:sub(1, -5)
    local scheme_domain, path = body:match("^([%a%d%+%.%-]+://[^/]+)(/?.*)$")
    local prefix = ""
    local max_prefix = 27
    if scheme_domain then
        if #scheme_domain > max_prefix then
            prefix = scheme_domain:sub(1, max_prefix)
        else
            local avail = max_prefix - #scheme_domain
            if path and avail > 2 then
                prefix = scheme_domain .. path:sub(1, avail)
            else
                prefix = scheme_domain .. "/"
            end
        end
    else
        prefix = body:sub(1, max_prefix)
    end
    return prefix .. "••••" .. tail
end

-- Запись текста в файл (атомарно, с проверкой ошибок)
local function write_to_file(path, content)
    local f = io.open(path, "w")
    if f then
        f:write(content)
        f:close()
        return true
    end
    return false
end

-- Запись в UCI под общей блокировкой.
-- Скрипт может работать одновременно в нескольких экземплярах (cron, кнопки в LuCI),
-- а параллельные set/commit в libuci теряют изменения друг друга: подписка так и остаётся
-- в статусе "Обновление...". Блокировка + свежий курсор на каждую запись это исключают.
local function uci_write(fn)
    local lock_fh = nixio.open("/tmp/subconv.lock", "w")
    if lock_fh then pcall(lock_fh.lock, lock_fh, "lock") end

    local u = require("luci.model.uci").cursor()
    fn(u)
    u:commit("subconv")

    if lock_fh then
        pcall(lock_fh.lock, lock_fh, "ulock")
        lock_fh:close()
    end
end

-- Сохранение статуса последней операции в UCI
local function save_status(status_text)
    if sub_id then
        uci_write(function(u)
            u:set("subconv", sub_id, "last_type", status_text)
        end)
        -- Сбрасываем серверный кэш статуса для мгновенного обновления в веб-интерфейсе
        os.remove("/tmp/subconv_status.json")
    end
end

-- Аварийное завершение работы с записью ошибки в лог и статусы
local function exit_with_error(log_msg, status_msg)
    log("ОШИБКА: " .. log_msg)
    save_status(status_msg or "Ошибка")
    os.exit(1)
end

-- ==========================================
-- Логика парсинга данных подписки (биллинг)
-- ==========================================
-- Читает служебные заголовки ответа (subscription-userinfo)
local function parse_userinfo(header_file)
    local f = io.open(header_file, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    os.remove(header_file)

    -- Ищем заголовок subscription-userinfo (регистронезависимо)
    for line in content:gmatch("[^\r\n]+") do
        local uinfo = line:match("^[Ss][Uu][Bb][Ss][Cc][Rr][Ii][Pp][Tt][Ii][Oo][Nn]%-[Uu][Ss][Ee][Rr][Ii][Nn][Ff][Oo]:%s*(.-)%s*$")
        if uinfo then
            local upload = tonumber(uinfo:match("upload=(%d+)") or 0) or 0
            local download = tonumber(uinfo:match("download=(%d+)") or 0) or 0
            local total = tonumber(uinfo:match("total=(%d+)") or 0) or 0
            local expire = tonumber(uinfo:match("expire=(%d+)") or 0) or 0
            local used = upload + download
            return string.format("%.0f|%.0f|%.0f", used, total, expire)
        end
    end
    return nil
end

-- ==========================================
-- Логика скачивания подписки (HTTP GET)
-- ==========================================
local function fetch_subscription(url, ua, hwid, dev_os, dev_model, header_output)
    local tmp_file = "/tmp/sub_resp_" .. (sub_id or "tmp") .. ".bin"
    os.remove(tmp_file)

    -- Формируем команду curl с эмуляцией заголовков клиента (строго по стандарту 0.3.15)
    local cmd = string.format(
        "curl -k -L -s --connect-timeout 15 -m 30 " ..
        "-A %s " ..
        "-H %s -H %s -H %s " ..
        "-D %s " ..
        "-w '%%{http_code}' " ..
        "%s -o %s",
        util.shellquote(ua),
        util.shellquote("X-HWID: " .. hwid),
        util.shellquote("X-DEVICE-OS: " .. dev_os),
        util.shellquote("X-DEVICE-MODEL: " .. dev_model),
        util.shellquote(header_output),
        util.shellquote(url),
        util.shellquote(tmp_file)
    )

    -- Выполняем curl и читаем возвращенный HTTP-код
    local pipe = io.popen(cmd)
    local http_code = pipe:read("*all")
    pipe:close()

    local f = io.open(tmp_file, "rb")
    local body = f and f:read("*all") or ""
    if f then f:close() end
    os.remove(tmp_file)

    -- Возвращаем тело ответа вместе с кодом состояния
    return body .. (http_code or "000")
end

-- ==========================================
-- Точка входа в скрипт
-- ==========================================
local function main()

log("=== СТАРТ ОБНОВЛЕНИЯ ===")

-- Проверяем, передан ли ID подписки
if not sub_id or sub_id == "" then
    exit_with_error("Не указан ID подписки", "Ошибка (ID)")
end

-- Читаем конфигурацию подписки из /etc/config/subconv
local url = uci:get("subconv", sub_id, "url")
local ua = uci:get("subconv", sub_id, "user_agent") or "SubConv/1.0"
local hwid = uci:get("subconv", sub_id, "hwid") or "openwrt-router-default"
local dev_os = uci:get("subconv", sub_id, "device_os") or "OpenWrt"
local dev_model = uci:get("subconv", sub_id, "device_model") or "OpenWrt Router"
local out_path = "/www/" .. sub_id .. ".txt"

if not url or url == "" then
    exit_with_error("В конфигурации отсутствует URL", "Ошибка (URL)")
end

-- 1. Проверяем, является ли ссылка зашифрованной (happ://)
if url:match("^happ://") or url:match("^v2raytun://") then
    log("Обнаружена крипто-ссылка: " .. mask_url(url))
    local decryptor = "/usr/libexec/happ-decrypt"
    
    -- Проверяем наличие установленного Go-бинарника дешифратора
    if not nixio.fs.access(decryptor) then
        exit_with_error("Дешифратор happ-decrypt не установлен в /usr/libexec/happ-decrypt", "Нет дешифратора")
    end

    -- Записываем версию бинарника дешифратора в лог
    local v_handle = io.popen(decryptor .. " --version 2>/dev/null")
    local dec_ver = v_handle and v_handle:read("*l") or "unknown"
    if v_handle then v_handle:close() end
    log("Дешифратор: " .. dec_ver .. "...")

    -- Вызываем Go-бинарник для расшифровки ссылки
    local cmd = decryptor .. " " .. util.shellquote(url) .. " 2>&1"
    local p = io.popen(cmd)
    local out = p:read("*all")
    p:close()

    -- Ищем расшифрованный URL в выводе дешифратора
    local real_url = nil
    for line in out:gmatch("[^\r\n]+") do
        local u = line:match("^(https?://%S+)")
        if u then
            real_url = u
            break
        end
    end

    if not real_url or real_url == "" then
        exit_with_error("Не удалось расшифровать ссылку: " .. out:gsub("[\r\n]", " "), "Ошибка дешифровки")
    end

    log("Успешно расшифровано! Истинный URL: " .. mask_url(real_url))
    url = real_url
end

log("Запрос: " .. sub_id .. " (" .. mask_url(url) .. ")")
log("Заголовки: UA=" .. ua .. " | HWID=" .. hwid .. " | OS=" .. dev_os)
log("Отправка запроса к серверу...")

-- 3. Выполняем запрос к серверу провайдера
local hdr_file = "/tmp/sub_headers_" .. (sub_id or "tmp") .. ".tmp"
local resp_raw = fetch_subscription(url, ua, hwid, dev_os, dev_model, hdr_file)
local uinfo_str = parse_userinfo(hdr_file)
if uinfo_str and sub_id then
    uci_write(function(u)
        u:set("subconv", sub_id, "userinfo", uinfo_str)
    end)
    log("Тариф (структура): " .. uinfo_str)
end
if not resp_raw or #resp_raw < 3 then
    exit_with_error("Сервер не ответил (сбой сети или таймаут)", "Ошибка сети")
end

-- Отделяем HTTP-код состояния от тела ответа
local http_code = resp_raw:sub(-3)
local resp = resp_raw:sub(1, -4)

log("HTTP Код: " .. tostring(http_code))

if #resp == 0 then
    exit_with_error("Пустое тело ответа", "Ошибка (HTTP " .. http_code .. "/Пусто)")
end

-- 4. Определение формата полученных данных (Base64 / Текст / JSON / YAML)
local decoded = resp
local is_b64 = false

-- Пробуем декодировать ответ из Base64
local b64_dec = nixio.bin.b64decode(resp)
if b64_dec and (b64_dec:match("://") or b64_dec:match("^%s*{") or b64_dec:match("^%s*%[") or b64_dec:match("proxies:") or b64_dec:match("^happ://")) then
    decoded = b64_dec
    is_b64 = true
    log("Декодирован Base64")
end

-- Проверяем, является ли ответ сырым массивом конфигурации (JSON/YAML)
local is_raw = decoded:match("^%s*{") or decoded:match("^%s*%[") or decoded:match("proxies:")

-- 5. Сохранение полученных узлов в локальный файл для HomeProxy
if is_raw then
    -- Сохраняем сырой конфиг как есть
    if write_to_file(out_path, decoded) then
        log("УСПЕХ: Сохранен как сырой конфиг (JSON/YAML)")
        save_status("JSON/YAML Конфиг")
    else
        exit_with_error("Не удалось записать файл " .. out_path, "Ошибка записи")
    end
else
    -- Парсим обычный текстовый список URI (vless://, vmess://)
    local links = {}
    for line in decoded:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line and (line:match("://") or line:match("^happ://")) then 
            table.insert(links, line) 
        end
    end

    if #links > 0 then
        if write_to_file(out_path, table.concat(links, "\n") .. "\n") then
            log("УСПЕХ: Найдено " .. #links .. " узлов URI")
            save_status(is_b64 and ("Base64 (" .. #links .. ")") or ("Текст (" .. #links .. ")"))
        else
            exit_with_error("Не удалось записать файл " .. out_path, "Ошибка записи")
        end
    else
        local snippet = decoded:sub(1, 50):gsub("[%c\n\r]", " ")
        exit_with_error("Узлы не найдены. Начало ответа: " .. snippet, "Пусто (Нет узлов)")
    end
end

end

-- Безопасный запуск с перехватом критических ошибок
local ok, err = xpcall(main, debug.traceback)
if not ok then
    local err_msg = tostring(err):gsub("\r?\n", " | ")
    log("КРИТИЧЕСКАЯ ОШИБКА СКРИПТА: " .. err_msg)
    save_status("Сбой скрипта")
    os.exit(1)
end
EOF

chmod +x /usr/libexec/subconv-update.sh

cat << 'EOF' > /usr/libexec/subconv-cron.sh
#!/bin/sh
# =====================================================================
# Скрипт синхронизации расписания Cron (subconv-cron.sh)
# =====================================================================
# Читает параметры interval из /etc/config/subconv и прописывает
# автоматические задачи обновления в /etc/crontabs/root.

CRON_FILE="/etc/crontabs/root"
mkdir -p /etc/crontabs
touch "$CRON_FILE"

# Удаляем старые задачи subconv перед обновлением расписания
sed -i '/subconv-update.sh/d' "$CRON_FILE"

if [ -f /etc/config/subconv ]; then
    SUBS=$(uci show subconv | grep "=subscription" | cut -d'.' -f2 | cut -d'=' -f1)
    
    for sub in $SUBS; do
        if [ -n "$sub" ]; then
            INTERVAL=$(uci -q get subconv."$sub".interval)
            
            # Настройка периодичности запуска в минутах/часах
            case "$INTERVAL" in
                "30")
                    echo "*/30 * * * * /usr/libexec/subconv-update.sh $sub >/dev/null 2>&1" >> "$CRON_FILE"
                    ;;
                "60")
                    echo "0 * * * * /usr/libexec/subconv-update.sh $sub >/dev/null 2>&1" >> "$CRON_FILE"
                    ;;
                "360")
                    echo "0 */6 * * * /usr/libexec/subconv-update.sh $sub >/dev/null 2>&1" >> "$CRON_FILE"
                    ;;
                "720")
                    echo "0 */12 * * * /usr/libexec/subconv-update.sh $sub >/dev/null 2>&1" >> "$CRON_FILE"
                    ;;
                "1440")
                    echo "0 4 * * * /usr/libexec/subconv-update.sh $sub >/dev/null 2>&1" >> "$CRON_FILE"
                    ;;
                "0"|"")
                    # Автообновление отключено
                    ;;
            esac
        fi
    done
fi

/etc/init.d/cron restart >/dev/null 2>&1
EOF

chmod +x /usr/libexec/subconv-cron.sh

cat << 'EOF' > /usr/share/luci/menu.d/subconv.json
{
    "admin/services/subconv": {
        "title": "Subconv",
        "action": {
            "type": "cbi",
            "path": "subconv"
        },
        "order": 90,
        "depends": {
            "uci": { "subconv": true }
        }
    }
}
EOF

cat << 'EOF' > /usr/share/rpcd/acl.d/subconv.json
{
    "luci-app-subconv": {
        "description": "Grant access to Subconv",
        "read": { "uci": [ "subconv" ] },
        "write": { "uci": [ "subconv" ] }
    }
}
EOF

cat << 'EOF' > /usr/lib/lua/luci/controller/subconv.lua
module("luci.controller.subconv", package.seeall)
function index()
    entry({"admin", "services", "subconv"}, cbi("subconv"), _("Subconv"), 90).dependent = true
    entry({"admin", "services", "subconv", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "subconv", "update_ajax"}, call("action_update_ajax")).leaf = true
    entry({"admin", "services", "subconv", "set_param"}, call("action_set_param")).leaf = true
end

local function format_sub_info(id, uinfo)
    local l2, l3 = "", ""
    if uinfo and uinfo ~= "" then
        local used, total, exp = uinfo:match("^(%d+)|(%d+)|(%d+)$")
        if used and total and exp then
            used, total, exp = tonumber(used), tonumber(total), tonumber(exp)
            local function fmt_b(b)
                if b >= 1073741824 then return string.format("%.1f ГБ", b / 1073741824)
                elseif b >= 1048576 then return string.format("%.1f МБ", b / 1048576)
                else return string.format("%.1f КБ", b / 1024) end
            end
            local has_exp = (exp and exp > 0)
            local exp_date = has_exp and os.date("%d.%m.%Y", exp) or "бессрочно"
            local now = os.time()
            local is_expired = has_exp and (exp < now)

            if total and total > 0 then
                local pct = math.min(100, math.floor((used / total) * 100))
                local bar_color = "#3b82f6"
                if is_expired then
                    bar_color = "#9ca3af"
                elseif pct >= 90 then
                    bar_color = "#ef4444"
                elseif pct >= 75 then
                    bar_color = "#f59e0b"
                end
                l2 = string.format(
                    '<div style="font-size: 11px; margin-bottom: 2px;">' ..
                    '<b>%s</b> / %s <span style="opacity: 0.6;">(%d%%)</span>' ..
                    '</div>' ..
                    '<div style="width: 100%%; background: #374151; border-radius: 3px; height: 5px; overflow: hidden; margin-bottom: 3px;">' ..
                    '<div style="width: %d%%; background: %s; height: 100%%; transition: width 0.3s;"></div>' ..
                    '</div>',
                    fmt_b(used), fmt_b(total), pct, pct, bar_color
                )
            elseif used > 0 then
                l2 = string.format('<div style="font-size: 11px; margin-bottom: 2px;">Использовано: <b>%s</b></div>', fmt_b(used))
            end

            if is_expired then
                l3 = string.format('<div style="font-size: 10px; color: #ef4444; font-weight: bold;">Истёк (%s)</div>', exp_date)
            elseif has_exp then
                local days_left = math.ceil((exp - now) / 86400)
                if days_left <= 0 then
                    l3 = string.format('<div style="font-size: 10px; color: #f59e0b; font-weight: bold;">Истекает сегодня (%s)</div>', exp_date)
                elseif days_left <= 3 then
                    l3 = string.format('<div style="font-size: 10px; color: #f59e0b;">Осталось %d дн. (до %s)</div>', days_left, exp_date)
                else
                    l3 = string.format('<div style="font-size: 10px; opacity: 0.6;">До %s (%d дн.)</div>', exp_date, days_left)
                end
            else
                l3 = '<div style="font-size: 10px; opacity: 0.6;">Срок: бессрочно</div>'
            end
        end
    end

    local local_link = "http://" .. luci.http.getenv("SERVER_NAME") .. "/" .. id .. ".txt"
    local esc_link = local_link:gsub('"', '&quot;')

    return string.format(
        '<div style="line-height: 1.3;">' ..
        '<div style="font-weight: bold; margin-bottom: 2px;">%s</div>' ..
        '%s%s' ..
        '<div class="subconv-code-cell" onclick="copyCell(this, this.getAttribute(\'data-copy\'))" data-copy="%s" title="Нажмите, чтобы скопировать" style="margin-top: 4px; font-size: 11px;">%s</div>' ..
        '</div>',
        id, l2, l3, esc_link, esc_link
    )
end

function action_status()
    local http = require "luci.http"
    local nixio = require "nixio"
    local cache_file = "/tmp/subconv_status.json"

    -- Серверная защита от DDoS / флуда: отдаем кэш из /tmp при повторных запросах чаще 1 сек
    local st = nixio.fs.stat(cache_file)
    if st and (os.time() - st.mtime < 1) then
        local cf = io.open(cache_file, "r")
        if cf then
            local cached = cf:read("*all")
            cf:close()
            if cached and #cached > 0 then
                http.prepare_content("application/json")
                http.write(cached)
                return
            end
        end
    end

    local uci = require "luci.model.uci".cursor()
    local items = {}
    uci:foreach("subconv", "subscription", function(s)
        local id = s[".name"]
        local lt = (s.last_type or ""):gsub('"', '\\"')
        local ui = (s.userinfo or ""):gsub('"', '\\"')
        local info_h = format_sub_info(id, s.userinfo):gsub('"', '\\"'):gsub('\r?\n', '')
        table.insert(items, string.format('"%s":{"last_type":"%s","userinfo":"%s","info_html":"%s"}', id, lt, ui, info_h))
    end)
    local json_str = "{" .. table.concat(items, ",") .. "}"

    local cf = io.open(cache_file, "w")
    if cf then
        cf:write(json_str)
        cf:close()
    end

    http.prepare_content("application/json")
    http.write(json_str)
end

function action_update_ajax()
    local http = require "luci.http"
    local uci = require "luci.model.uci".cursor()
    local util = require "luci.util"
    local sys = require "luci.sys"

    local sub = http.formvalue("sub")
    local update_all = http.formvalue("all")

    os.remove("/tmp/subconv_status.json")

    if update_all == "1" then
        -- 1) Сначала собираем ID подписок (конфигурацию внутри foreach не меняем)
        local ids = {}
        uci:foreach("subconv", "subscription", function(s)
            ids[#ids + 1] = s[".name"]
        end)

        if #ids > 0 then
            -- 2) Помечаем все подписки одним коммитом ДО запуска обновления
            for _, id in ipairs(ids) do
                uci:set("subconv", id, "last_type", "Обновление...")
            end
            uci:commit("subconv")

            -- 3) Один фоновый процесс обновляет подписки строго по очереди:
            --    параллельные записи в UCI теряли статусы, а провайдер видел несколько
            --    одновременных запросов с одним и тем же HWID
            local cmds = {}
            for _, id in ipairs(ids) do
                cmds[#cmds + 1] = "/usr/libexec/subconv-update.sh " .. util.shellquote(id)
            end
            sys.call("( " .. table.concat(cmds, "; ") .. " ) >/dev/null 2>&1 </dev/null &")
        end

        http.prepare_content("application/json")
        http.write('{"status":"ok","all":true}')
        return
    end

    if sub and sub ~= "" then
        local ua = http.formvalue("ua")
        if ua and ua ~= "" then
            uci:set("subconv", sub, "user_agent", ua)
        end
        uci:set("subconv", sub, "last_type", "Обновление...")
        uci:commit("subconv")
        sys.call("/usr/libexec/subconv-update.sh " .. util.shellquote(sub) .. " >/dev/null 2>&1 &")
        http.prepare_content("application/json")
        http.write('{"status":"ok","sub":"' .. sub .. '"}')
        return
    end

    http.prepare_content("application/json")
    http.write('{"status":"error","message":"no target"}')
end

function action_set_param()
    local http = require "luci.http"
    local sub = http.formvalue("sub")
    local key = http.formvalue("key")
    local val = http.formvalue("val")

    if sub and sub ~= "" and (key == "user_agent" or key == "interval") and val then
        local u = require("luci.model.uci").cursor()
        u:set("subconv", sub, key, val)
        u:commit("subconv")

        if key == "interval" then
            local sys = require "luci.sys"
            sys.call("/usr/libexec/subconv-cron.sh")
        end

        http.prepare_content("application/json")
        http.write('{"status":"ok"}')
        return
    end

    http.prepare_content("application/json")
    http.write('{"status":"error"}')
end
EOF

cat << 'EOF' > /usr/lib/lua/luci/model/cbi/subconv.lua
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local nixio = require "nixio"
local dsp = require "luci.dispatcher"
local http = require "luci.http"

-- ---------------------------------------------------------------------
-- 1. СБОР И ДЕТЕКЦИЯ СИСТЕМНЫХ ДАННЫХ РОУТЕРА
-- ---------------------------------------------------------------------

-- Автоопределение версии прошивки OpenWrt
local sys_os = "OpenWrt"
if nixio.fs.access("/etc/openwrt_release") then
    for line in io.lines("/etc/openwrt_release") do
        local id, rel = line:match('DISTRIB_ID=[\'"]?(.-)[\'"]?$'), line:match('DISTRIB_RELEASE=[\'"]?(.-)[\'"]?$')
        if id then sys_os = id end
        if rel then sys_os = sys_os .. " " .. rel end
    end
end

-- Автоопределение модели устройства
local sys_model = "OpenWrt Router"
if nixio.fs.access("/tmp/sysinfo/model") then
    local f_m = io.open("/tmp/sysinfo/model", "r")
    if f_m then
        local m_txt = f_m:read("*l")
        f_m:close()
        if m_txt and m_txt ~= "" then sys_model = m_txt end
    end
end

-- Получение постоянного уникального идентификатора оборудования (HWID)
local sys_hwid = ""
if nixio.fs.access("/etc/machine-id") then
    local f_hid = io.open("/etc/machine-id", "r")
    if f_hid then
        sys_hwid = f_hid:read("*l") or ""
        f_hid:close()
    end
end
if not sys_hwid or sys_hwid == "" then
    local rand_hex = nixio.bin.hexencode(nixio.crypto.hash("md5", tostring(os.time()) .. tostring(os.clock())))
    sys_hwid = string.format("%s-%s-%s-%s", rand_hex:sub(1,8), rand_hex:sub(9,12), rand_hex:sub(13,16), rand_hex:sub(17,28))
    local f_hid_w = io.open("/etc/machine-id", "w")
    if f_hid_w then
        f_hid_w:write(sys_hwid .. "\n")
        f_hid_w:close()
    end
end

-- Генерация динамического случайного HWID
local rnd_part = nixio.bin.hexencode(nixio.crypto.hash("sha1", tostring(os.time()) .. tostring(math.random(1000, 9999))))
local random_hwid = string.format("%s-%s-%s", rnd_part:sub(1, 8), rnd_part:sub(9, 12), rnd_part:sub(13, 20))

-- ---------------------------------------------------------------------
-- 2. СИСТЕМА САМООБНОВЛЕНИЯ ПЛАГИНА (GITHUB RELEASES)
-- ---------------------------------------------------------------------
local current_ver = "0.3.16"

-- Обработка клика по кнопке "Обновить плагин"
if http.formvalue("subconv_self_update") then
    os.remove("/tmp/subconv_ver_cache")
    local update_cmd = "curl -fsSL --connect-timeout 10 https://raw.githubusercontent.com/asimoneo/subconv/main/install.sh -o /tmp/subconv_install.sh && sh /tmp/subconv_install.sh -s 1"
    sys.call(update_cmd)
    http.redirect(dsp.build_url("admin", "services", "subconv"))
    return
end

-- Проверка доступности новой версии через GitHub API (с кэшированием)
local latest_ver = current_ver
local has_update = false
local now = os.time()
local cache_file = "/tmp/subconv_ver_cache"
local cache_valid = false

local f_c = io.open(cache_file, "r")
if f_c then
    local c_time = tonumber(f_c:read("*l") or 0) or 0
    local c_ver = f_c:read("*l")
    f_c:close()
    if (now - c_time) < 1800 and c_ver and c_ver ~= "" then
        latest_ver = c_ver
        cache_valid = true
    end
end

if not cache_valid then
    local ver_cmd = "curl -sSL --connect-timeout 3 -H 'User-Agent: Subconv-Updater' https://api.github.com/repos/asimoneo/subconv/releases/latest 2>/dev/null | grep '\"tag_name\":' | head -n 1 | sed -E 's/.*\"tag_name\":[[:space:]]*\"([^\"]+)\".*/\\1/' | sed 's/^v//'"
    local p_ver = io.popen(ver_cmd)
    if p_ver then
        local net_ver = p_ver:read("*l")
        p_ver:close()
        if net_ver and net_ver ~= "" and net_ver:match("^%d+%.%d+%.%d+") then
            latest_ver = net_ver:match("^%d+%.%d+%.%d+")
            local f_cw = io.open(cache_file, "w")
            if f_cw then
                f_cw:write(now .. "\n" .. latest_ver .. "\n")
                f_cw:close()
            end
        end
    end
end

-- Сравнение семантических номеров версий
local function parse_semver(v)
    local ma, mi, pa = v:match("^(%d+)%.(%d+)%.(%d+)")
    return tonumber(ma or 0), tonumber(mi or 0), tonumber(pa or 0)
end

local c_ma, c_mi, c_pa = parse_semver(current_ver)
local l_ma, l_mi, l_pa = parse_semver(latest_ver)

if (l_ma > c_ma) or (l_ma == c_ma and l_mi > c_mi) or (l_ma == c_ma and l_mi == c_mi and l_pa > c_pa) then
    has_update = true
end

-- Формирование бейджа версии в заголовке
local title_html = string.format([[
<div style="display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px;">
    <div style="display: flex; align-items: center; gap: 10px;">
        <span style="font-size: 20px; font-weight: bold;">Subconv</span>
        <span class="subconv-ver-badge">v%s</span>
    </div>
]], current_ver)

if has_update then
    title_html = title_html .. string.format([[
    <div style="display: flex; align-items: center; gap: 8px;">
        <span style="color: #f59e0b; font-size: 13px; font-weight: 500;">Доступно обновление: v%s</span>
        <button type="button" class="cbi-button cbi-button-apply" style="padding: 2px 10px; font-size: 12px; margin: 0;" onclick="triggerSelfUpdate(this)">🚀 Обновить сейчас</button>
    </div>
]], latest_ver)
end
title_html = title_html .. "</div>"

-- Чтение журнала отладки для вывода в консоль внизу страницы
local debug_content = ""
local dbg_f = io.open("/www/subconv_debug.txt", "r")
if dbg_f then
    debug_content = dbg_f:read("*all")
    dbg_f:close()
else
    debug_content = "Журнал отладки пуст."
end

-- ---------------------------------------------------------------------
-- 3. СТИЛИ И ИНТЕРФЕЙС (CSS И JS)
-- ---------------------------------------------------------------------
local CSS_TWEAKS = [===[<style>
  /* 1. Блок заголовка: выравнивание по левому краю, ширина 100% */
  .subconv-header {
    width: 100% !important;
    max-width: 100% !important;
    margin-left: 0 !important;
    margin-right: 0 !important;
    margin-bottom: 20px !important;
    box-sizing: border-box !important;
    padding-left: 0 !important;
  }
  .subconv-ver-badge {
    background: #0ea5e9;
    color: #ffffff;
    font-size: 11px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 12px;
    display: inline-block;
    letter-spacing: 0.5px;
  }

  /* 2. Спойлер "Добавить новую подписку": по умолчанию свернут */
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]),
  .subconv-add-section {
    border-radius: 8px !important;
    margin-bottom: 24px !important;
    padding: 0 16px 8px 16px !important;
    position: relative !important;
    transition: all 0.25s ease !important;
    width: 100% !important;
    box-sizing: border-box !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) > legend,
  .subconv-add-section > legend {
    cursor: pointer !important;
    user-select: none !important;
    font-size: 15px !important;
    font-weight: 600 !important;
    padding: 10px 14px 10px 32px !important;
    margin-left: -16px !important;
    margin-right: -16px !important;
    display: block !important;
    width: calc(100% + 32px) !important;
    box-sizing: border-box !important;
    position: relative !important;
    border-radius: 8px 8px 0 0 !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) > legend::before,
  .subconv-add-section > legend::before {
    content: "▶" !important;
    position: absolute !important;
    left: 14px !important;
    top: 50% !important;
    transform: translateY(-50%) !important;
    font-size: 11px !important;
    transition: transform 0.2s ease !important;
    opacity: 0.7 !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]).expanded > legend::before,
  .subconv-add-section.expanded > legend::before {
    transform: translateY(-50%) rotate(90deg) !important;
  }

  /* 3. Фиксированное позиционирование кнопки дешифратора в углу спойлера */
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .subconv-decrypt-row,
  .subconv-add-section .subconv-decrypt-row {
    position: absolute !important;
    top: 6px !important;
    right: 14px !important;
    margin: 0 !important;
    padding: 0 !important;
    border: none !important;
    z-index: 10 !important;
    background: transparent !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .subconv-decrypt-row .cbi-value-title,
  .subconv-add-section .subconv-decrypt-row .cbi-value-title {
    display: none !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .subconv-decrypt-row .cbi-value-field,
  .subconv-add-section .subconv-decrypt-row .cbi-value-field {
    padding: 0 !important;
    margin: 0 !important;
    display: flex !important;
    align-items: center !important;
    gap: 8px !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .subconv-decrypt-row .cbi-button,
  .subconv-add-section .subconv-decrypt-row .cbi-button {
    height: 28px !important;
    padding: 2px 10px !important;
    font-size: 11px !important;
    margin: 0 !important;
  }

  /* 4. Выравнивание полей формы спойлера по левому краю */
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-section-node,
  .subconv-add-section .cbi-section-node {
    padding-left: 0 !important;
    margin-left: 0 !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value,
  .subconv-add-section .cbi-value {
    padding-left: 0 !important;
    margin-left: 0 !important;
  }

  /* 5. Интерактивные ячейки копирования (URL, HWID и т.д.) */
  .subconv-code-cell {
    font-family: monospace;
    cursor: pointer;
    display: inline-block;
    padding: 1px 4px;
    border-radius: 4px;
    transition: background 0.15s ease, color 0.15s ease;
    user-select: all;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    vertical-align: middle;
  }
  .subconv-code-cell:hover {
    background: rgba(14, 165, 233, 0.15);
    color: #0ea5e9;
  }
  .subconv-code-cell.copied {
    background: rgba(16, 185, 129, 0.25) !important;
    color: #10b981 !important;
  }

  /* 6. Таблица активных подписок */
  .cbi-section-table {
    table-layout: auto !important;
    width: 100% !important;
    border-collapse: collapse !important;
  }
  .cbi-section-table th,
  .cbi-section-table td {
    vertical-align: middle !important;
    padding: 7px 6px !important;
    white-space: nowrap !important;
    overflow: hidden !important;
    text-overflow: ellipsis !important;
    box-sizing: border-box !important;
  }

  /* Базовая ширина колонок */
  .cbi-section-table th:nth-child(1), .cbi-section-table td:nth-child(1) { width: 14%; max-width: 130px; }
  .cbi-section-table th:nth-child(2), .cbi-section-table td:nth-child(2) { width: 15%; max-width: 135px; }
  .cbi-section-table th:nth-child(3), .cbi-section-table td:nth-child(3) { width: 11%; max-width: 95px; }
  .cbi-section-table th:nth-child(4), .cbi-section-table td:nth-child(4) { width: 11%; max-width: 95px; }
  .cbi-section-table th:nth-child(5), .cbi-section-table td:nth-child(5) { width: 11%; max-width: 95px; }
  .cbi-section-table th:nth-child(6), .cbi-section-table td:nth-child(6) { width: 11%; max-width: 95px; }
  .cbi-section-table th:nth-child(7), .cbi-section-table td:nth-child(7) { width: 14%; min-width: 110px; }
  .cbi-section-table th:nth-child(8), .cbi-section-table td:nth-child(8) { width: 13%; min-width: 100px; }
  .cbi-section-table th:nth-child(9), .cbi-section-table td:nth-child(9) { width: 44px !important; min-width: 44px !important; max-width: 44px !important; text-align: center !important; padding-left: 2px !important; padding-right: 2px !important; }
  .cbi-section-table th:nth-child(10), .cbi-section-table td:nth-child(10) { width: 44px !important; min-width: 44px !important; max-width: 44px !important; text-align: center !important; padding-left: 2px !important; padding-right: 2px !important; }

  /* Нативные выпадающие списки (User-Agent и Cron) */
  .cbi-section-table td:nth-child(2) select,
  .cbi-section-table td:nth-child(2) .cbi-dropdown,
  .cbi-section-table td:nth-child(6) select,
  .cbi-section-table td:nth-child(6) .cbi-dropdown {
    width: 100% !important;
    max-width: 100% !important;
    box-sizing: border-box !important;
    margin: 0 !important;
    padding-top: 3px !important;
    padding-bottom: 3px !important;
    height: 30px !important;
    line-height: 24px !important;
    font-size: 12px !important;
  }
  .cbi-section-table td:nth-child(2) .cbi-dropdown-entry,
  .cbi-section-table td:nth-child(6) .cbi-dropdown-entry {
    padding-left: 4px !important;
    padding-right: 4px !important;
    font-size: 12px !important;
  }

  /* Кнопки действий: компактный квадратный вид с крупными эмодзи */
  .subconv-action-btn {
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    width: 32px !important;
    min-width: 32px !important;
    max-width: 32px !important;
    height: 32px !important;
    padding: 0 !important;
    margin: 0 auto !important;
    font-size: 16px !important;
    line-height: 1 !important;
    border-radius: 6px !important;
    cursor: pointer !important;
    box-sizing: border-box !important;
    text-decoration: none !important;
    transition: transform 0.1s ease, background-color 0.15s ease !important;
  }
  .subconv-action-btn:hover {
    transform: scale(1.08) !important;
  }
  .subconv-action-btn:active {
    transform: scale(0.95) !important;
  }
  .subconv-action-btn span {
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    width: 100% !important;
    height: 100% !important;
    margin: 0 !important;
    padding: 0 !important;
    line-height: 1 !important;
  }

  /* 7. Анимация вращения индикатора загрузки */
  @keyframes subconv-spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
  }
  .subconv-spin {
    display: inline-block !important;
    animation: subconv-spin 1s linear infinite !important;
    transform-origin: center center !important;
    line-height: 1 !important;
  }

  /* 8. Кнопка "Добавить подписку" по центру внизу формы */
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value:has(button[name*="_add"], input[name*="_add"]),
  .subconv-add-section .cbi-value:has(button[name*="_add"], input[name*="_add"]) {
    display: flex !important;
    justify-content: center !important;
    align-items: center !important;
    margin-top: 22px !important;
    margin-bottom: 6px !important;
    padding: 0 !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value:has(button[name*="_add"], input[name*="_add"]) .cbi-value-title,
  .subconv-add-section .cbi-value:has(button[name*="_add"], input[name*="_add"]) .cbi-value-title {
    display: none !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value:has(button[name*="_add"], input[name*="_add"]) .cbi-value-field,
  .subconv-add-section .cbi-value:has(button[name*="_add"], input[name*="_add"]) .cbi-value-field {
    display: flex !important;
    justify-content: center !important;
    align-items: center !important;
    margin: 0 !important;
    padding: 0 !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value:has(button[name*="_add"], input[name*="_add"]) .cbi-button,
  .subconv-add-section .cbi-value:has(button[name*="_add"], input[name*="_add"]) .cbi-button {
    min-width: 240px !important;
    height: 38px !important;
    padding: 6px 28px !important;
    font-size: 14px !important;
    font-weight: 500 !important;
    background: #059669 !important;
    border: 1px solid #10b981 !important;
    color: #ffffff !important;
    border-radius: 6px !important;
    box-shadow: 0 2px 8px rgba(16, 185, 129, 0.25) !important;
    cursor: pointer !important;
    letter-spacing: 0.3px !important;
    transition: all 0.2s ease !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value:has(button[name*="_add"], input[name*="_add"]) .cbi-button:hover,
  .subconv-add-section .cbi-value:has(button[name*="_add"], input[name*="_add"]) .cbi-button:hover {
    background: #10b981 !important;
    box-shadow: 0 4px 14px rgba(16, 185, 129, 0.4) !important;
    transform: translateY(-1px) !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value:not(:has(button[name*="_add"])) .cbi-value-title,
  .subconv-add-section .cbi-value:not(:has(button[name*="_add"])) .cbi-value-title {
    display: block !important;
    visibility: visible !important;
    opacity: 1 !important;
  }

  /* 9. Журнал отладки: 100% ширина, моноширинный шрифт и автоскролл */
  #cbi-subconv-global,
  fieldset.cbi-section:has(#subconv-debug-log) {
    width: 100% !important;
    max-width: 100% !important;
    margin-left: 0 !important;
    margin-right: 0 !important;
    box-sizing: border-box !important;
    padding-left: 0 !important;
    padding-right: 0 !important;
    display: block !important;
  }
  #cbi-subconv-global .cbi-section-node,
  fieldset.cbi-section:has(#subconv-debug-log) .cbi-section-node,
  #cbi-subconv-global .cbi-value,
  fieldset.cbi-section:has(#subconv-debug-log) .cbi-value,
  #cbi-subconv-global .cbi-value-field,
  fieldset.cbi-section:has(#subconv-debug-log) .cbi-value-field {
    width: 100% !important;
    max-width: 100% !important;
    margin: 0 !important;
    padding: 0 !important;
    box-sizing: border-box !important;
    display: block !important;
  }
  fieldset.cbi-section:has(#subconv-debug-log) .cbi-value-title {
    display: none !important;
  }
  #subconv-debug-log {
    width: 100% !important;
    max-width: 100% !important;
    height: 180px !important;
    box-sizing: border-box !important;
    display: block !important;
    font-family: monospace !important;
    font-size: 11px !important;
    line-height: 1.4 !important;
    padding: 8px 10px !important;
    border-radius: 4px !important;
    resize: vertical !important;
    white-space: pre !important;
    overflow-x: auto !important;
    overflow-y: scroll !important;
  }
</style>
]===]

local JS_TWEAKS_TEMPLATE = [===[<script>
(function() {
    // Вспомогательная функция копирования текста в буфер обмена
    window.copyCell = function(el, text) {
        if (!text) return;
        var toCopy = text.trim();
        var done = function() {
            if (el) {
                var orig = el.innerText;
                el.classList.add('copied');
                el.innerText = 'Скопировано!';
                setTimeout(function() {
                    el.classList.remove('copied');
                    el.innerText = orig;
                }, 1200);
            }
        };

        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(toCopy).then(done).catch(function() {
                fallbackCopy(toCopy, done);
            });
        } else {
            fallbackCopy(toCopy, done);
        }
    };

    function fallbackCopy(text, cb) {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.top = '0';
        ta.style.left = '0';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.focus();
        ta.select();
        try {
            document.execCommand('copy');
            if (cb) cb();
        } catch(e) {}
        document.body.removeChild(ta);
    }

    // Инициализация кастомного заголовка и сворачиваемого спойлера
    function initHeaderAndSections() {
        var h2 = document.querySelector('h2');
        if (h2 && !h2.dataset.subconvInit) {
            h2.dataset.subconvInit = 'true';
            h2.classList.add('subconv-header');
            h2.innerHTML = '%s';
        }

        var addSection = document.querySelector('fieldset:has([name="cbid.subconv.add.sub_id"])') ||
                         document.querySelector('#cbi-subconv-add:not(:has(textarea))');
        if (addSection) {
            addSection.classList.add('subconv-add-section');

            var dlRow = addSection.querySelector('.cbi-value:has([name*="_dl_decrypt"])');
            if (dlRow) {
                dlRow.classList.add('subconv-decrypt-row');
            }

            function updateFormVisibility() {
                var isExp = addSection.classList.contains('expanded');
                var rows = addSection.querySelectorAll('.cbi-value');
                rows.forEach(function(r) {
                    if (r.classList.contains('subconv-decrypt-row')) {
                        r.style.setProperty('display', 'block', 'important');
                    } else {
                        r.style.setProperty('display', isExp ? 'flex' : 'none', 'important');
                    }
                });
            }

            var legend = addSection.querySelector('legend');
            var btnToggle = addSection.querySelector('.subconv-spoiler-toggle');
            if (legend && !legend.dataset.spoilerInit) {
                legend.dataset.spoilerInit = 'true';
                legend.style.cursor = 'pointer';
                legend.onclick = function(e) {
                    if (e.target.closest('.subconv-decrypt-row') || e.target.closest('.cbi-button')) return;
                    addSection.classList.toggle('expanded');
                    updateFormVisibility();
                };
            }

            if (btnToggle) {
                btnToggle.onclick = function() {
                    addSection.classList.toggle('expanded');
                    updateFormVisibility();
                };
            }

            if (addSection.querySelector('.cbi-value-error') || document.querySelector('.cbi-message-reset, .alert-message')) {
                addSection.classList.add('expanded');
            }

            var btnSubmitAdd = addSection.querySelector('button[name*="_add"], input[name*="_add"]');
            if (btnSubmitAdd && !btnSubmitAdd.dataset.valInit) {
                btnSubmitAdd.dataset.valInit = 'true';
                btnSubmitAdd.addEventListener('click', function(e) {
                    var idInp = document.querySelector('[name="cbid.subconv.add.sub_id"]');
                    var urlInp = document.querySelector('[name="cbid.subconv.add.url"]');
                    if (!idInp || !urlInp) return;

                    var idVal = (idInp.value || '').trim();
                    var urlVal = (urlInp.value || '').trim();

                    if (!idVal) {
                        alert('Ошибка: Укажите имя подписки (ID)!');
                        idInp.focus();
                        e.preventDefault();
                        e.stopPropagation();
                        return false;
                    }

                    if (!/^[a-zA-Z0-9_]+$/.test(idVal)) {
                        alert('Ошибка: Имя подписки (ID) должно содержать только латинские буквы, цифры и знак подчеркивания!');
                        idInp.focus();
                        e.preventDefault();
                        e.stopPropagation();
                        return false;
                    }

                    if (idVal === 'add' || idVal === 'global' || idVal === 'subscription') {
                        alert('Ошибка: Имя "' + idVal + '" зарезервировано системой!');
                        idInp.focus();
                        e.preventDefault();
                        e.stopPropagation();
                        return false;
                    }

                    if (document.querySelector('.subconv-info-cell[data-sub="' + idVal + '"]')) {
                        alert('Ошибка: Подписка с именем "' + idVal + '" уже существует!');
                        idInp.focus();
                        e.preventDefault();
                        e.stopPropagation();
                        return false;
                    }

                    if (!urlVal) {
                        alert('Ошибка: Укажите URL подписки!');
                        urlInp.focus();
                        e.preventDefault();
                        e.stopPropagation();
                        return false;
                    }

                    if (/\s/.test(urlVal)) {
                        alert('Ошибка: URL подписки не должен содержать пробелы!');
                        urlInp.focus();
                        e.preventDefault();
                        e.stopPropagation();
                        return false;
                    }

                    if (!/^(https?:\/\/[a-zA-Z0-9.\-_]+|happ:\/\/|v2raytun:\/\/)/i.test(urlVal)) {
                        alert('Ошибка: Некорректный URL подписки! Ссылка должна начинаться с http://, https://, happ:// или v2raytun://');
                        urlInp.focus();
                        e.preventDefault();
                        e.stopPropagation();
                        return false;
                    }

                    var cleanUrl = urlVal.replace(/\/+$/, '').toLowerCase();
                    var isDup = false;
                    var dupId = '';
                    document.querySelectorAll('.cbi-section-table [data-sub-url], .cbi-section-table [data-copy]').forEach(function(el) {
                        var existing = (el.getAttribute('data-sub-url') || el.getAttribute('data-copy') || '').trim();
                        if (existing && existing.replace(/\/+$/, '').toLowerCase() === cleanUrl) {
                            isDup = true;
                            var row = el.closest('tr');
                            if (row) {
                                var sCell = row.querySelector('.subconv-info-cell');
                                dupId = sCell ? (sCell.getAttribute('data-sub') || '') : '';
                            }
                        }
                    });

                    if (isDup) {
                        alert('Ошибка: Подписка с таким URL уже добавлена' + (dupId ? ' (ID: ' + dupId + ')' : '') + '!');
                        urlInp.focus();
                        e.preventDefault();
                        e.stopPropagation();
                        return false;
                    }
                }, true);
            }

            updateFormVisibility();
        }
    }

    function initTableChangeHandlers() {
        var table = document.querySelector('.cbi-section-table');
        if (!table || table.dataset.handlersInit) return;
        table.dataset.handlersInit = 'true';

        function syncField(target) {
            if (!target) return;
            var el = target.closest('[name*="cbid.subconv."]') || target;
            var name = el.getAttribute('name') || el.name || '';
            var m = name.match(/^cbid\.subconv\.([^.]+)\.(user_agent|interval)$/);
            if (!m && target.querySelector) {
                var real = target.querySelector('[name*="cbid.subconv."]');
                if (real) {
                    el = real;
                    name = el.getAttribute('name') || el.name || '';
                    m = name.match(/^cbid\.subconv\.([^.]+)\.(user_agent|interval)$/);
                }
            }
            if (m) {
                var sId = m[1];
                var key = m[2];
                var val = el.value !== undefined && el.value !== null ? el.value : el.getAttribute('value');
                if (val === undefined || val === null || val === '') {
                    var inner = el.querySelector ? el.querySelector('input, select') : null;
                    if (inner) val = inner.value;
                }
                if (val !== undefined && val !== null) {
                    var url = window.location.pathname.replace(/\/+$/, '') + '/set_param?sub=' + encodeURIComponent(sId) + '&key=' + encodeURIComponent(key) + '&val=' + encodeURIComponent(val);
                    fetch(url, { cache: 'no-store' })
                        .catch(function(e) { console.error('Save param error', e); });
                }
            }
        }

        table.addEventListener('change', function(e) { syncField(e.target); }, true);
        table.addEventListener('cbi-dropdown-change', function(e) { syncField(e.target); }, true);
        table.addEventListener('blur', function(e) { syncField(e.target); }, true);
    }

    function alignFormAndTable() {
        initHeaderAndSections();
        initTableChangeHandlers();

        document.querySelectorAll('.cbi-section-descr, span').forEach(function(s) {
            if (s.innerText && s.innerText.indexOf('процесс может занять некоторое время') !== -1) {
                s.remove();
            }
        });

        // Настройка ячеек таблицы подписок для клика и копирования
        document.querySelectorAll('.cbi-section-table tr.cbi-section-table-row').forEach(function(row) {
            [1, 3, 4, 5].forEach(function(idx) {
                var cell = row.children[idx - 1];
                if (cell) {
                    var d = cell.querySelector('.subconv-code-cell') || cell.querySelector('div') || cell;
                    d.title = 'Нажмите, чтобы скопировать';
                    if (!d.onclick) {
                        d.onclick = function() { copyCell(this, this.getAttribute('data-copy') || this.innerText.trim()); };
                    }
                }
            });
        });

        // Выравнивание журнала отладки строго по ширине таблицы (на всю ширину)
        var logTa = document.getElementById('subconv-debug-log');
        if (logTa) {
            var cur = logTa.parentElement;
            while (cur && cur.tagName !== 'FORM' && cur.tagName !== 'BODY') {
                if (cur.classList.contains('cbi-value-field') || 
                    cur.classList.contains('cbi-value') || 
                    cur.classList.contains('cbi-section-node') ||
                    cur.tagName === 'FIELDSET') {
                    cur.style.setProperty('width', '100%', 'important');
                    cur.style.setProperty('max-width', '100%', 'important');
                    cur.style.setProperty('margin-left', '0', 'important');
                    cur.style.setProperty('margin-right', '0', 'important');
                    cur.style.setProperty('padding-left', '0', 'important');
                    cur.style.setProperty('padding-right', '0', 'important');
                    cur.style.setProperty('box-sizing', 'border-box', 'important');
                    cur.style.setProperty('display', 'block', 'important');
                }
                var lbl = cur.querySelector('.cbi-value-title');
                if (lbl && cur.contains(logTa)) {
                    lbl.style.setProperty('display', 'none', 'important');
                }
                cur = cur.parentElement;
            }
        }

        var subIdInput = document.querySelector('[name="cbid.subconv.add.sub_id"]');
        if (subIdInput) {
            var subIdRow = subIdInput.closest('.cbi-value');
            if (subIdRow) {
                var titleEl = subIdRow.querySelector('.cbi-value-title');
                if (titleEl) {
                    titleEl.style.setProperty('display', 'block', 'important');
                    titleEl.style.setProperty('visibility', 'visible', 'important');
                    titleEl.style.setProperty('opacity', '1', 'important');
                    if (!titleEl.innerText || titleEl.innerText.trim() === '') {
                        titleEl.innerText = 'Имя подписки (ID)';
                    }
                }
            }
        }

        // Автоскролл консоли логов вниз
        var dbg = document.getElementById('subconv-debug-log');
        if (dbg && !dbg.dataset.scrolled) {
            dbg.scrollTop = dbg.scrollHeight;
            dbg.dataset.scrolled = 'true';
        }
    }

    // Фоновое обновление содержимого лога отладки без перезагрузки всей страницы
    function refreshDebugLog() {
        var logTa = document.getElementById('subconv-debug-log');
        if (!logTa) return;
        fetch('/subconv_debug.txt?_t=' + Date.now(), { cache: 'no-store' })
            .then(function(res) { return res.text(); })
            .then(function(txt) {
                if (txt && logTa.value !== txt) {
                    var shouldScroll = (logTa.scrollTop + logTa.clientHeight >= logTa.scrollHeight - 50);
                    logTa.value = txt;
                    if (shouldScroll) {
                        logTa.scrollTop = logTa.scrollHeight;
                    }
                }
            })
            .catch(function() {});
    }

    // Обновление одной подписки через AJAX
    function triggerSubUpdate(btn, subId) {
        if (!subId) return;
        if (btn) {
            btn.disabled = true;
            btn.innerHTML = '<span class="subconv-spin">🔄</span>';
        }

        var statusEl = document.querySelector('.subconv-status-cell[data-sub="' + subId + '"]');
        if (statusEl) {
            statusEl.innerHTML = '<span class="subconv-status-updating" data-sub="' + subId + '" style="display:inline-flex; align-items:center; gap:4px; font-weight:500; color:#2563eb;"><span class="subconv-spin">🔄</span> Обновление...</span>';
        }

        var row = btn ? btn.closest('tr') : null;
        var uaVal = '';
        if (row) {
            var uaEl = row.querySelector('[name="cbid.subconv.' + subId + '.user_agent"]') ||
                       row.querySelector('[name*="' + subId + '.user_agent"]');
            if (uaEl) {
                var innerInp = uaEl.querySelector ? uaEl.querySelector('input:not([type="hidden"])') : null;
                if (innerInp && innerInp.value && innerInp.value !== '-- пользовательский --') {
                    uaVal = innerInp.value;
                } else if (uaEl.value !== undefined && uaEl.value !== null && uaEl.value !== '') {
                    uaVal = uaEl.value;
                } else {
                    var anyInp = uaEl.querySelector ? uaEl.querySelector('input, select') : null;
                    uaVal = anyInp ? anyInp.value : (uaEl.getAttribute('value') || '');
                }
            }
        }

        var url = window.location.pathname.replace(/\/+$/, '') + '/update_ajax?sub=' + encodeURIComponent(subId);
        if (uaVal) {
            url += '&ua=' + encodeURIComponent(uaVal);
        }
        fetch(url, { cache: 'no-store' })
            .catch(function(e) { console.error('Update trigger error', e); });

        refreshDebugLog();
        initStatusWatcher();
    }

    function triggerUpdateAll(btn) {
        if (btn) {
            btn.disabled = true;
            btn.innerHTML = '<span class="subconv-spin">🔄</span> Обновление...';
        }

        document.querySelectorAll('.subconv-status-cell').forEach(function(el) {
            var s = el.getAttribute('data-sub');
            if (s) {
                el.innerHTML = '<span class="subconv-status-updating" data-sub="' + s + '" style="display:inline-flex; align-items:center; gap:4px; font-weight:500; color:#2563eb;"><span class="subconv-spin">🔄</span> Обновление...</span>';
            }
        });

        document.querySelectorAll('.cbi-section-table button[onclick*="triggerSubUpdate"]').forEach(function(b) {
            b.disabled = true;
            var sId = '';
            var m = b.getAttribute('onclick') && b.getAttribute('onclick').match(/triggerSubUpdate\(this,\s*'([^']+)'\)/);
            if (m) {
                sId = m[1];
                b.disabled = true;
                b.innerHTML = '<span class="subconv-spin">🔄</span>';
                var sEl = document.querySelector('.subconv-status-cell[data-sub="' + sId + '"]');
                if (sEl) {
                    sEl.innerHTML = '<span class="subconv-status-updating" data-sub="' + sId + '" style="display:inline-flex; align-items:center; gap:4px; font-weight:500; color:#2563eb;"><span class="subconv-spin">🔄</span> Обновление...</span>';
                }
            }
        });

        var table = document.querySelector('.cbi-section-table');
        if (table) {
            table.querySelectorAll('[name*=".user_agent"]').forEach(function(inp) {
                var name = inp.name || inp.getAttribute('name') || '';
                var m = name.match(/^cbid\.subconv\.([^.]+)\.user_agent$/);
                var val = inp.value !== undefined && inp.value !== null ? inp.value : inp.getAttribute('value');
                if (!val && inp.querySelector) {
                    var inner = inp.querySelector('input, select');
                    if (inner) val = inner.value;
                }
                if (m && val) {
                    var sUrl = window.location.pathname.replace(/\/+$/, '') + '/set_param?sub=' + encodeURIComponent(m[1]) + '&key=user_agent&val=' + encodeURIComponent(val);
                    fetch(sUrl, { cache: 'no-store' });
                }
            });
        }

        var url = window.location.pathname.replace(/\/+$/, '') + '/update_ajax?all=1';
        fetch(url, { cache: 'no-store' })
            .catch(function(e) { console.error('Update all trigger error', e); });

        refreshDebugLog();
        initStatusWatcher();
    }

    function initStatusWatcher() {
        if (window.__subconv_watcher_running) return;
        var targets = document.querySelectorAll('.subconv-status-updating');
        if (!targets.length) return;
        window.__subconv_watcher_running = true;

        var attempts = 0;
        // Подписки обновляются по очереди, поэтому время ожидания растёт с их количеством
        var maxAttempts = 20 + 10 * Math.max(0, targets.length - 1);
        var isRequestPending = false;
        var retryDelay = 2000;

        var logTimer = setInterval(refreshDebugLog, 1500);

        function stopWatcher(reason) {
            window.__subconv_watcher_running = false;
            if (logTimer) { clearInterval(logTimer); logTimer = null; }
            refreshDebugLog();

            var btnAll = document.querySelector('button[onclick*="triggerUpdateAll"]');
            if (btnAll) {
                btnAll.disabled = false;
                btnAll.innerHTML = '🔄 Обновить все';
            }
            if (reason === 'timeout') {
                document.querySelectorAll('.subconv-status-updating').forEach(function(el) {
                    el.innerHTML = '<span style="color:#d97706; font-size:12px; font-weight:500;">⚠️ Таймаут</span> <a href="" onclick="location.reload();return false;" style="margin-left:3px; font-size:11px; text-decoration:underline; color:#2563eb;">[обновить]</a>';
                });
                document.querySelectorAll('button[onclick*="triggerSubUpdate"]').forEach(function(b) {
                    b.disabled = false;
                    b.innerHTML = '🔄';
                });
            }
        }

        function poll() {
            if (!window.__subconv_watcher_running) return;

            if (document.hidden) {
                setTimeout(poll, 3000);
                return;
            }

            attempts++;
            if (attempts > maxAttempts) {
                stopWatcher('timeout');
                return;
            }

            if (isRequestPending) {
                setTimeout(poll, 1000);
                return;
            }

            isRequestPending = true;
            var statusUrl = window.location.pathname.replace(/\/+$/, '') + '/status';

            fetch(statusUrl, { cache: 'no-store' })
                .then(function(res) {
                    if (!res.ok) throw new Error('HTTP ' + res.status);
                    return res.json();
                })
                .then(function(data) {
                    isRequestPending = false;
                    retryDelay = 2000;
                    var stillUpdating = false;

                    document.querySelectorAll('.subconv-status-updating').forEach(function(el) {
                        var sub = el.getAttribute('data-sub');
                        if (data && data[sub]) {
                            var st = data[sub].last_type;
                            if (st && st !== 'Обновление...') {
                                var statusCell = document.querySelector('.subconv-status-cell[data-sub="' + sub + '"]');
                                if (statusCell) {
                                    statusCell.innerHTML = st;
                                }

                                var infoCell = document.querySelector('.subconv-info-cell[data-sub="' + sub + '"]');
                                if (infoCell && data[sub].info_html) {
                                    infoCell.innerHTML = data[sub].info_html;
                                }

                                document.querySelectorAll('button[onclick*="triggerSubUpdate"]').forEach(function(b) {
                                    if (b.getAttribute('onclick').indexOf("'" + sub + "'") !== -1) {
                                        b.disabled = false;
                                        b.innerHTML = '🔄';
                                    }
                                });
                            } else {
                                stillUpdating = true;
                            }
                        }
                    });

                    refreshDebugLog();

                    if (!document.querySelectorAll('.subconv-status-updating').length || !stillUpdating) {
                        stopWatcher('done');
                    } else {
                        setTimeout(poll, retryDelay);
                    }
                })
                .catch(function() {
                    isRequestPending = false;
                    retryDelay = Math.min(retryDelay * 1.5, 5000);
                    setTimeout(poll, retryDelay);
                });
        }

        setTimeout(poll, 1000);
    }

    setTimeout(function() {
        alignFormAndTable();
        initStatusWatcher();
    }, 200);
    setTimeout(alignFormAndTable, 600);
</script>
<button type="submit" name="subconv_self_update" value="1" id="subconv_self_update_btn" style="display:none;"></button>]===]

local m = Map("subconv", "Subconv", translate("Парсинг подписок и конвертация в удобные списки серверов для раздачи другим плагинам/девайсам."))

-- ------------------------------------------
-- СЕКЦИЯ 1: Добавление новой подписки
-- ------------------------------------------
local s_add = m:section(NamedSection, "add", "global", "")
s_add.addremove = false
s_add.anonymous = true

local f_id = s_add:option(Value, "sub_id", translate("Имя подписки (ID)"))
f_id.description = translate("Только латиница без пробелов. Задает имя выходного файла ({ID}.txt).")
f_id.rmempty = true

local f_url = s_add:option(Value, "url", translate("URL подписки"))
f_url.description = translate("Прямая ссылка от провайдера (поддерживаются форматы URI, YAML, JSON, happ://crypt5).")
f_url.rmempty = true

local f_ua = s_add:option(Value, "user_agent", translate("User-Agent"))
f_ua.description = translate("на основании user agent сервер может адаптировать выдачу")
f_ua:value("SubConv/1.0", "SubConv/1.0 (По умолчанию)")
f_ua:value("sing-box/1.9.3", "sing-box 1.9.3")
f_ua:value("mihomo/1.18.3", "mihomo 1.18.3 (Clash.Meta)")
f_ua:value("Happ/SC", "Happ/SC")
f_ua:value("v2rayN/6.42", "v2rayN 6.42")
f_ua:value("Shadowrocket/1982", "Shadowrocket/1982")
f_ua.default = "SubConv/1.0"
f_ua.rmempty = true

local f_hwid_opt = s_add:option(Value, "hwid", translate("HWID устройства"))
f_hwid_opt.description = translate("Уникальный идентификатор устройства. Защищает от блокировки за мультиаккаунт.")
f_hwid_opt:value(random_hwid, random_hwid .. " (Случайный - По умолчанию)")
f_hwid_opt:value(sys_hwid, sys_hwid .. " (Ваш роутер)")
f_hwid_opt.default = random_hwid
f_hwid_opt.rmempty = true

local f_os = s_add:option(Value, "device_os", translate("OS Устройства"))
f_os.description = translate("Операционная система, которая будет указана в заголовках запроса.")
f_os:value(sys_os, sys_os)
f_os:value("Windows 11", "Windows 11")
f_os:value("iOS 17.0", "iOS 17.0")
f_os:value("Android 14", "Android 14")
f_os.default = sys_os
f_os.rmempty = true

local f_model = s_add:option(Value, "device_model", translate("Модель Устройства"))
f_model.description = translate("Название устройства для передачи провайдеру.")
f_model:value(sys_model, sys_model)
f_model:value("PC", "PC")
f_model:value("iPhone 15 Pro", "iPhone 15 Pro")
f_model:value("Android Phone", "Android Phone")
f_model.default = sys_model
f_model.rmempty = true

local f_interval = s_add:option(ListValue, "interval", translate("Интервал обновления"))
f_interval.description = translate("Как часто роутер будет автоматически скачивать свежие узлы (через Cron).")
f_interval:value("0", translate("Отключено"))
f_interval:value("30", translate("Каждые 30 мин"))
f_interval:value("60", translate("Каждый 1 час"))
f_interval:value("360", translate("Каждые 6 часов"))
f_interval:value("720", translate("Каждые 12 часов"))
f_interval:value("1440", translate("Раз в сутки"))
f_interval.default = "1440"

local f_decrypt = s_add:option(Button, "_dl_decrypt", translate("Дешифратор happ://"))
f_decrypt.inputtitle = translate("Скачать / Обновить")
f_decrypt.inputstyle = "apply"
function f_decrypt.cfgvalue(self, section)
    local bin_path = "/usr/libexec/happ-decrypt"
    if nixio.fs.access(bin_path) then
        local v_handle = io.popen(bin_path .. " --version 2>/dev/null")
        local bin_ver = v_handle and v_handle:read("*l") or "unknown"
        if v_handle then v_handle:close() end
        self.description = "<span style='color:#4caf50; font-weight:bold;'>✅ Установлен (" .. bin_ver .. ")</span>"
    else
        self.description = "<span style='color:#ff9800; font-weight:bold;'>⚠️ Не установлен</span> (Нажмите для загрузки)"
    end
end
function f_decrypt.write(self, section)
    local cmd = "COMMIT_SHA=$(curl -sSL --connect-timeout 5 https://api.github.com/repos/asimoneo/subconv/commits/main 2>/dev/null | grep '\"sha\"' | head -n 1 | awk -F '\"' '{print $4}'); " ..
                "if [ -n \"$COMMIT_SHA\" ]; then " ..
                "curl -fsSL \"https://raw.githubusercontent.com/asimoneo/subconv/${COMMIT_SHA}/happ-decrypt\" -o /usr/libexec/happ-decrypt; " ..
                "else " ..
                "curl -fsSL \"https://raw.githubusercontent.com/asimoneo/subconv/refs/heads/main/happ-decrypt\" -o /usr/libexec/happ-decrypt; " ..
                "fi; chmod +x /usr/libexec/happ-decrypt"
    sys.call(cmd)
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

local f_js = s_add:option(DummyValue, "_js_tweaks")
f_js.rawhtml = true
function f_js.cfgvalue()
    return CSS_TWEAKS .. string.format(JS_TWEAKS_TEMPLATE, current_ver, title_html:gsub("'", "\\'"))
end

local btn_add = s_add:option(Button, "_add", "")
btn_add.inputtitle = translate("➕ Добавить подписку")
btn_add.inputstyle = "add"
function btn_add.write(self, section)
    local raw_id = m:formvalue("cbid.subconv.add.sub_id") or ""
    local raw_url = m:formvalue("cbid.subconv.add.url") or ""
    local new_id = raw_id:gsub("^%s+", ""):gsub("%s+$", "")
    local new_url = raw_url:gsub("^%s+", ""):gsub("%s+$", "")

    if new_id == "" then
        m.message = "Ошибка: Укажите имя подписки (ID)!"
        return
    end

    if not new_id:match("^[%w_]+$") then
        m.message = "Ошибка: Имя подписки должно содержать только латинские буквы, цифры и знак подчеркивания!"
        return
    end

    if new_id == "add" or new_id == "global" or new_id == "subscription" then
        m.message = "Ошибка: Имя '" .. new_id .. "' зарезервировано системой!"
        return
    end

    if uci:get("subconv", new_id) then
        m.message = "Ошибка: Подписка с именем '" .. new_id .. "' уже существует!"
        return
    end

    if new_url == "" then
        m.message = "Ошибка: Укажите URL подписки!"
        return
    end

    if new_url:match("%s") or new_url:match("[\r\n]") then
        m.message = "Ошибка: URL подписки не должен содержать пробелы и переносы строк!"
        return
    end

    -- Проверка протокола и формата URL: поддерживаются http://, https://, happ://, v2raytun://
    local is_http = new_url:match("^https?://[%w%.%-%_]+%S*")
    local is_happ = new_url:match("^happ://%S+")
    local is_v2t  = new_url:match("^v2raytun://%S+")
    if not (is_http or is_happ or is_v2t) then
        m.message = "Ошибка: Некорректный URL подписки! Ссылка должна начинаться с http://, https:// или happ://"
        return
    end

    -- Проверка на дубликат URL
    local dup_sub = nil
    local norm_new_url = new_url:gsub("/+$", "")
    uci:foreach("subconv", "subscription", function(s)
        local cur_u = (s.url or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
        if cur_u ~= "" and cur_u == norm_new_url then
            dup_sub = s[".name"] or "существующая"
        end
    end)

    if dup_sub then
        m.message = "Ошибка: Подписка с таким URL уже существует (ID: " .. dup_sub .. ")!"
        return
    end

    local new_ua = m:formvalue("cbid.subconv.add.user_agent") or "SubConv/1.0"
    local new_hwid = m:formvalue("cbid.subconv.add.hwid") or random_hwid
    local new_os = m:formvalue("cbid.subconv.add.device_os") or sys_os
    local new_model = m:formvalue("cbid.subconv.add.device_model") or sys_model
    local new_interval = m:formvalue("cbid.subconv.add.interval") or "1440"

    uci:section("subconv", "subscription", new_id, {
        url = new_url,
        user_agent = new_ua,
        hwid = new_hwid,
        device_os = new_os,
        device_model = new_model,
        interval = new_interval,
        last_type = "Ожидание..."
    })
    uci:set("subconv", "add", "sub_id", "")
    uci:set("subconv", "add", "url", "")
    uci:commit("subconv")
    
    sys.call("/usr/libexec/subconv-update.sh " .. util.shellquote(new_id) .. " >/dev/null 2>&1 &")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

-- ------------------------------------------
-- СЕКЦИЯ 2: Таблица активных подписок
-- ------------------------------------------
local list_title = translate("Активные подписки") .. [[ <button type="button" onclick="triggerUpdateAll(this)" class="cbi-button cbi-button-apply" style="margin-left: 15px; font-size: 12px; padding: 4px 12px;" title="Обновить все подписки">🔄 Обновить все</button> <span style="font-weight: normal; font-size: 12px; opacity: 0.7; margin-left: 10px;">(процесс может занять некоторое время)</span>]]
local s_list = m:section(TypedSection, "subscription", list_title)
s_list.anonymous = true
s_list.addremove = false
s_list.template = "cbi/tblsection"

-- Кол 1: URL
local url_list = s_list:option(DummyValue, "url", translate("URL"))
url_list.rawhtml = true
function url_list.cfgvalue(self, section)
    local val = uci:get("subconv", section, "url") or ""
    local esc_val = val:gsub('"', '&quot;')
    
    local display_val = ""
    if #val <= 18 then
        display_val = esc_val
    else
        local tail = val:sub(-4)
        local body = val:sub(1, -5)
        local scheme_domain, path = body:match("^([%a%d%+%.%-]+://[^/]+)(/?.*)$")
        local prefix = ""
        local max_prefix = 27
        if scheme_domain then
            if #scheme_domain > max_prefix then
                prefix = scheme_domain:sub(1, max_prefix)
            else
                local avail = max_prefix - #scheme_domain
                if path and avail > 2 then
                    prefix = scheme_domain .. path:sub(1, avail)
                else
                    prefix = scheme_domain .. "/"
                end
            end
        else
            prefix = body:sub(1, max_prefix)
        end
        display_val = prefix .. "••••" .. tail
    end
    display_val = display_val:gsub('"', '&quot;')

    return string.format('<div class="subconv-code-cell" onclick="copyCell(this, this.getAttribute(\'data-copy\'))" data-copy="%s" data-sub-url="%s" title="Нажмите, чтобы скопировать">%s</div>', esc_val, esc_val, display_val)
end

-- Кол 2: User-Agent (родной выпадающий список LuCI с возможностью ввести свой вариант)
local ua_list = s_list:option(Value, "user_agent", translate("User-Agent"))
ua_list:value("SubConv/1.0", "SubConv/1.0 (По умолчанию)")
ua_list:value("sing-box/1.9.3", "sing-box 1.9.3")
ua_list:value("mihomo/1.18.3", "mihomo 1.18.3 (Clash.Meta)")
ua_list:value("Happ/SC", "Happ/SC")
ua_list:value("v2rayN/6.42", "v2rayN 6.42")
ua_list:value("Shadowrocket/1982", "Shadowrocket/1982")
ua_list.rmempty = false

-- Кол 3: HWID
local hwid_opt = s_list:option(DummyValue, "hwid", translate("HWID"))
hwid_opt.rawhtml = true
function hwid_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "hwid") or ""
    local esc_val = val:gsub('"', '&quot;')
    return string.format('<div class="subconv-code-cell" onclick="copyCell(this, this.getAttribute(\'data-copy\'))" data-copy="%s" title="Нажмите, чтобы скопировать">%s</div>', esc_val, esc_val)
end

-- Кол 4: OS
local os_opt = s_list:option(DummyValue, "device_os", translate("OS"))
os_opt.rawhtml = true
function os_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "device_os") or ""
    local esc_val = val:gsub('"', '&quot;')
    return string.format('<div class="subconv-code-cell" onclick="copyCell(this, this.getAttribute(\'data-copy\'))" data-copy="%s" title="Нажмите, чтобы скопировать">%s</div>', esc_val, esc_val)
end

-- Кол 5: Модель
local model_opt = s_list:option(DummyValue, "device_model", translate("Модель"))
model_opt.rawhtml = true
function model_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "device_model") or ""
    local esc_val = val:gsub('"', '&quot;')
    return string.format('<div class="subconv-code-cell" onclick="copyCell(this, this.getAttribute(\'data-copy\'))" data-copy="%s" title="Нажмите, чтобы скопировать">%s</div>', esc_val, esc_val)
end

-- Кол 6: Интервал обновления Cron
local interval_list = s_list:option(ListValue, "interval", translate("Обновление"))
interval_list:value("0", translate("Откл"))
interval_list:value("30", translate("30 мин"))
interval_list:value("60", translate("1 час"))
interval_list:value("360", translate("6 часов"))
interval_list:value("720", translate("12 часов"))
interval_list:value("1440", translate("24 часа"))
interval_list.default = "1440"
function interval_list.write(self, section, value)
    uci:set("subconv", section, "interval", value)
    uci:commit("subconv")
    sys.call("/usr/libexec/subconv-cron.sh")
end

-- Кол 7: Статус последней операции
local last_status = s_list:option(DummyValue, "last_type", translate("Статус"))
last_status.rawhtml = true
function last_status.cfgvalue(self, section)
    local st = uci:get("subconv", section, "last_type") or "Ожидание..."
    if st == "Обновление..." then
        return string.format('<span class="subconv-status-cell" data-sub="%s"><span class="subconv-status-updating" data-sub="%s" style="display:inline-flex; align-items:center; gap:4px; font-weight:500; color:#2563eb;"><span class="subconv-spin">🔄</span> Обновление...</span></span>', section, section)
    end
    return string.format('<span class="subconv-status-cell" data-sub="%s">%s</span>', section, st)
end

-- Кол 8: Имя / Данные тарифа / Ссылка
local info_col = s_list:option(DummyValue, "_info", translate("Данные подписки"))
info_col.rawhtml = true
function info_col.cfgvalue(self, section)
    local uinfo = uci:get("subconv", section, "userinfo")
    return string.format('<span class="subconv-info-cell" data-sub="%s">%s</span>', section, format_sub_info(section, uinfo))
end

-- Кол 9: Кнопка обновления одной подписки
local btn_upd = s_list:option(DummyValue, "_btn_update", "")
btn_upd.rawhtml = true
function btn_upd.cfgvalue(self, section)
    return string.format('<button type="button" class="cbi-button cbi-button-apply subconv-action-btn" title="Обновить сейчас" onclick="triggerSubUpdate(this, \'%s\')"><span>🔄</span></button>', section)
end

-- Кол 10: Кнопка удаления подписки
local btn_del = s_list:option(Button, "_del", "")
btn_del.inputtitle = "🗑️"
btn_del.inputstyle = "reset subconv-action-btn"
function btn_del.render(self, section, scope)
    self.title = ""
    Button.render(self, section, scope)
end
function btn_del.write(self, section)
    uci:delete("subconv", section)
    uci:commit("subconv")
    os.remove("/www/" .. section .. ".txt")
    sys.call("/usr/libexec/subconv-cron.sh")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

-- ------------------------------------------
-- СЕКЦИЯ 3: Журнал отладки
-- ------------------------------------------
local s_dbg = m:section(NamedSection, "global", "global", translate("Журнал отладки"))
s_dbg.anonymous = true
local f_dbg_view = s_dbg:option(TextValue, "_debug_log")
f_dbg_view.rows = 8
f_dbg_view.readonly = true
f_dbg_view.wrap = "off"
function f_dbg_view.cfgvalue()
    local f = io.open("/www/subconv_debug.txt", "r")
    if f then
        local c = f:read("*all")
        f:close()
        return c
    end
    return "Журнал отладки пуст."
end
function f_dbg_view.render(self, section, scope)
    self.template = "cbi/tvalue"
    self.id = "subconv-debug-log"
    TextValue.render(self, section, scope)
end

return m
EOF

# Инициализация конфигурационного файла по умолчанию, если он отсутствует
if [ ! -f /etc/config/subconv ]; then
    touch /etc/config/subconv
    uci set subconv.global=global
    uci set subconv.add=global
    uci commit subconv
fi

# Настройка сервиса и синхронизация cron
/usr/libexec/subconv-cron.sh
rm -rf /tmp/luci-* /tmp/rpcd-* /tmp/state/*
/etc/init.d/rpcd restart

echo ""
echo "======================================================"
echo "          Subconv v${VERSION} успешно установлен!        "
echo "======================================================"
