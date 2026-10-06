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

end -- main

-- Страховка: любая непредвиденная ошибка Lua попадает в журнал и в статус подписки,
-- а не оставляет её навсегда в состоянии "Обновление..."
local ok, err = xpcall(main, debug.traceback)
if not ok then
    log("КРИТИЧЕСКАЯ ОШИБКА СКРИПТА: " .. tostring(err):gsub("[\r\n]+", " | "))
    pcall(save_status, "Ошибка скрипта")
    os.exit(1)
end
EOF
chmod +x /usr/libexec/subconv-update.sh

cat << 'EOF' > /usr/libexec/subconv-cron.sh
#!/bin/sh
# =====================================================================
# Скрипт синхронизации расписания Cron для подписок
# =====================================================================

. /lib/functions.sh

if [ -f /etc/crontabs/root ]; then
    sed -i '/subconv-update.sh/d' /etc/crontabs/root
fi

add_cron() {
    local cfg="$1"
    local interval
    config_get interval "$cfg" interval "1440"
    
    if [ "$interval" != "0" ]; then
        local cron_expr=""
        case "$interval" in
            "30")   cron_expr="*/30 * * * *" ;;
            "60")   cron_expr="0 * * * *" ;;
            "360")  cron_expr="0 */6 * * *" ;;
            "720")  cron_expr="0 */12 * * *" ;;
            "1440") cron_expr="0 4 * * *" ;;
            *)      cron_expr="0 4 * * *" ;;
        esac
        
        if [ -n "$cron_expr" ]; then echo "$cron_expr /usr/libexec/subconv-update.sh $cfg >/dev/null 2>&1" >> /etc/crontabs/root; fi
    fi
}
config_load subconv
config_foreach add_cron subscription
/etc/init.d/cron restart
EOF
chmod +x /usr/libexec/subconv-cron.sh

cat << 'EOF' > /usr/share/luci/menu.d/subconv.json
{
    "admin/services/subconv": {
        "title": "Subconv",
        "order": 90,
        "action": { "type": "cbi", "path": "subconv" },
        "depends": { "acl": [ "luci-app-subconv" ] }
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
            local days_left = has_exp and math.max(0, math.floor((exp - now) / 86400)) or nil

            local d_str = nil
            if has_exp then
                local ld, lt = days_left % 10, days_left % 100
                if lt >= 11 and lt <= 19 then d_str = days_left .. " дней"
                elseif ld == 1 then d_str = days_left .. " день"
                elseif ld >= 2 and ld <= 4 then d_str = days_left .. " дня"
                else d_str = days_left .. " дней" end
            end

            local inf_icon = [[<span style="font-size: 20px; font-weight: bold; line-height: 1; vertical-align: -2px; margin-right: 4px; display: inline-block;">∞</span>]]

            if total > 0 then
                local left_b = math.max(0, total - used)
                l2 = string.format([[<div style="font-size: 11px; opacity: 0.9; margin-top: 2px; white-space: nowrap;">%s / %s до %s</div>]], fmt_b(used), fmt_b(total), exp_date)
                if is_expired then
                    l3 = [[<div style="font-size: 11px; color: #ff5555; font-weight: bold; margin-top: 1px; white-space: nowrap;">Срок истёк</div>]]
                elseif left_b <= 0 then
                    l3 = [[<div style="font-size: 11px; color: #ff5555; font-weight: bold; margin-top: 1px; white-space: nowrap;">Трафик исчерпан</div>]]
                elseif has_exp then
                    if days_left == 0 then
                        l3 = string.format([[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Осталось: %s (истекает сегодня)</div>]], fmt_b(left_b))
                    else
                        l3 = string.format([[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Осталось: %s на %s</div>]], fmt_b(left_b), d_str)
                    end
                else
                    l3 = string.format([[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Осталось: %s</div>]], fmt_b(left_b))
                end
            else
                if has_exp then
                    l2 = string.format([[<div style="font-size: 11px; opacity: 0.9; margin-top: 2px; white-space: nowrap;">%sдо %s</div>]], inf_icon, exp_date)
                    if is_expired then
                        l3 = [[<div style="font-size: 11px; color: #ff5555; font-weight: bold; margin-top: 1px; white-space: nowrap;">Срок истёк</div>]]
                    elseif days_left == 0 then
                        l3 = [[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Истекает сегодня</div>]]
                    else
                        l3 = string.format([[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Осталось: %s</div>]], d_str)
                    end
                else
                    l2 = string.format([[<div style="font-size: 11px; opacity: 0.9; margin-top: 2px; white-space: nowrap;">%sбез ограничений</div>]], inf_icon)
                    l3 = [[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Бессрочно</div>]]
                end
            end
        end
    else
        l2 = [[<div style="font-size: 11px; opacity: 0.5; margin-top: 2px; white-space: nowrap;">(нет данных)</div>]]
    end
    return string.format([[<div style="line-height: 1.3; white-space: nowrap;"><div style="font-size: 13px; font-weight: bold;">%s</div>%s%s</div>]], id, l2, l3)
end

function action_status()
    local nixio = require "nixio"
    local http = require "luci.http"
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
local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local http = require "luci.http"
local dsp = require "luci.dispatcher"
local util = require "luci.util"
local nixio = require "nixio"

-- =====================================================================
-- Главный визуальный модуль LuCI (SubConv)
-- Отображает интерфейс, обрабатывает добавление, удаление и обновление.
-- =====================================================================

local function get_sys_info()
    local os_ver = "OpenWrt"
    local f_rel = io.open("/etc/openwrt_release", "r")
    if f_rel then
        local c = f_rel:read("*all")
        f_rel:close()
        for l in c:gmatch("[^\r\n]+") do
            if l:match("^DISTRIB_ID=") then os_ver = l:match([=[DISTRIB_ID=['"]?(.-)['"]?$]=]) end
            if l:match("^DISTRIB_RELEASE=") then
                local rel = l:match([=[DISTRIB_RELEASE=['"]?(.-)['"]?$]=])
                if rel then os_ver = os_ver .. " " .. rel end
            end
        end
    end

    local model = "OpenWrt Router"
    local f_mod = io.open("/tmp/sysinfo/model", "r")
    if f_mod then
        local m_val = f_mod:read("*all")
        f_mod:close()
        if m_val and m_val ~= "" then model = m_val:gsub("^%s+", ""):gsub("%s+$", "") end
    end

    local hwid = "openwrt-router-default"
    local f_hwid = io.open("/etc/machine-id", "r")
    if f_hwid then
        local hw = f_hwid:read("*all"):gsub("^%s+", ""):gsub("%s+$", "")
        if hw ~= "" then hwid = hw end
        f_hwid:close()
    end

    local rnd_hwid = sys.exec("cat /proc/sys/kernel/random/uuid 2>/dev/null"):gsub("-", ""):gsub("%s+", ""):sub(1, 16)
    if not rnd_hwid or rnd_hwid == "" then rnd_hwid = "happ" .. tostring(os.time()) end

    return os_ver:gsub("[\r\n]", ""), model:gsub("[\r\n]", ""), hwid:gsub("[\r\n]", ""), rnd_hwid:gsub("[\r\n]", "")
end

local sys_os, sys_model, sys_hwid, random_hwid = get_sys_info()

-- ==========================================
-- Константы для HTML и JavaScript
-- ==========================================
local current_ver = "0.3.16"

local title_html = [[<a href="https://github.com/asimoneo/subconv" target="_blank" style="text-decoration:none; color:inherit; border-bottom: 1px dashed;">Subconv</a> <span style="font-size: 14px; opacity: 0.6; font-weight: normal; margin-left: 8px;" id="plugin-ver-text">v]] .. current_ver .. [[</span> <button type="button" class="cbi-button" style="margin-left: 10px; font-size: 12px; padding: 2px 6px;" id="btn-check-ver" onclick="checkPluginVersion()">Проверить обновления</button><button type="button" class="cbi-button cbi-button-apply" style="margin-left: 5px; font-size: 12px; padding: 2px 6px; display: none;" id="btn-do-update" onclick="doPluginUpdate()">Обновить</button>]]

local CSS_TWEAKS = [===[<style>
  /* 1. Выделение и плавная анимация (0.8с) раскрытия формы добавления */
  .subconv-add-section.expanded,
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]).expanded {
    max-height: 900px !important;
    opacity: 1 !important;
    overflow: visible !important;
    visibility: visible !important;
    border: 1px solid rgba(16, 185, 129, 0.45) !important;
    background: rgba(16, 185, 129, 0.03) !important;
    border-radius: 8px !important;
    padding: 15px 20px 20px 20px !important;
    margin-top: 15px !important;
    margin-bottom: 25px !important;
    box-shadow: 0 4px 16px rgba(16, 185, 129, 0.08) !important;
    transition: max-height 0.8s cubic-bezier(0.4, 0, 0.2, 1),
                opacity 0.8s ease,
                padding 0.8s ease,
                margin 0.8s ease !important;
  }
  .subconv-add-section:not(.expanded),
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]):not(.expanded) {
    max-height: 0 !important;
    opacity: 0 !important;
    overflow: hidden !important;
    padding-top: 0 !important;
    padding-bottom: 0 !important;
    margin-top: 0 !important;
    margin-bottom: 0 !important;
    border-top-width: 0 !important;
    border-bottom-width: 0 !important;
    border-left: 1px solid transparent !important;
    border-right: 1px solid transparent !important;
    pointer-events: none !important;
    visibility: hidden !important;
    transition: max-height 0.8s cubic-bezier(0.4, 0, 0.2, 1),
                opacity 0.6s ease,
                padding 0.8s ease,
                margin 0.8s ease,
                visibility 0.8s !important;
  }

  /* Скрываем дублирующий/внешний заголовок формы */
  .subconv-add-section h3,
  .subconv-add-section legend,
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) > h3,
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) > legend {
    display: none !important;
  }

  /* 2. Поля формы добавления: единая ширина 250px, подсказки справа */
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value-field {
    display: flex !important;
    flex-direction: row !important;
    align-items: center !important;
    gap: 15px !important;
    flex-wrap: nowrap !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value-field > input:not(.cbi-button),
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value-field > select,
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value-field > .cbi-dropdown,
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value-field > cbi-dropdown {
    width: 250px !important;
    max-width: 250px !important;
    min-width: 250px !important;
    flex: 0 0 250px !important;
    box-sizing: border-box !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value-description {
    margin: 0 !important;
    padding: 0 !important;
    opacity: 0.8 !important;
    font-size: 12px !important;
    white-space: nowrap !important;
    flex: 1 1 auto !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-dropdown ul > li {
    white-space: normal !important;
    line-height: 1.3 !important;
  }

  /* 3. Кнопка проверки версии в шапке */
  #btn-check-ver, #btn-do-update {
    font-size: 13px !important;
    padding: 4px 10px !important;
    height: 30px !important;
    line-height: 20px !important;
    box-sizing: border-box !important;
    vertical-align: middle !important;
  }

  /* 4. Дешифратор в строке заголовка Активные подписки */
  #subconv-decrypt-bar {
    display: inline-flex !important;
    align-items: center !important;
    gap: 8px !important;
    margin: 0 0 0 15px !important;
    padding: 0 !important;
    background: transparent !important;
    border: none !important;
    box-shadow: none !important;
    font-size: 13px !important;
    font-weight: normal !important;
    vertical-align: middle !important;
  }
  #subconv-decrypt-bar::before {
    content: "|" !important;
    opacity: 0.3 !important;
    margin-right: 6px !important;
    font-weight: normal !important;
  }
  #subconv-decrypt-bar .cbi-value-title {
    width: auto !important;
    padding: 0 !important;
    margin: 0 !important;
    font-size: 13px !important;
    font-weight: 500 !important;
    opacity: 0.9 !important;
    display: inline !important;
  }
  #subconv-decrypt-bar .cbi-value-field {
    display: inline-flex !important;
    align-items: center !important;
    gap: 8px !important;
    width: auto !important;
    margin: 0 !important;
    padding: 0 !important;
  }
  #subconv-decrypt-bar .cbi-value-description {
    margin: 0 !important;
    padding: 0 !important;
    font-size: 12px !important;
    white-space: nowrap !important;
  }
  #subconv-decrypt-bar .cbi-button {
    margin: 0 !important;
    font-size: 12px !important;
    padding: 3px 10px !important;
    height: 26px !important;
    line-height: 18px !important;
  }

  /* ========================================================= */
  /* 5. ПОЛНОСТЬЮ ПЕРЕВЕРСТАННАЯ ТАБЛИЦА АКТИВНЫХ ПОДПИСОК      */
  /* ========================================================= */
  .cbi-section-table {
    width: 100% !important;
    max-width: 100% !important;
    table-layout: auto !important;
    border-collapse: separate !important;
    border-spacing: 0 !important;
    box-sizing: border-box !important;
  }
  .cbi-section-table th,
  .cbi-section-table td {
    padding: 6px 4px !important;
    vertical-align: middle !important;
    text-align: left !important;
    box-sizing: border-box !important;
  }
  .cbi-section-table th {
    font-size: 12px !important;
    font-weight: 600 !important;
    opacity: 0.85 !important;
    white-space: nowrap !important;
    border-bottom: 1px solid rgba(255, 255, 255, 0.1) !important;
  }
  .cbi-section-table tr.cbi-section-table-row td,
  .cbi-section-table tr[class*="cbi-section-table-row"] td {
    border-bottom: 1px solid rgba(255, 255, 255, 0.05) !important;
  }

  /* Интерактивные кликабельные поля: обводка и фон только при :hover */
  .subconv-code-cell {
    display: inline-block !important;
    position: relative !important;
    max-width: 100% !important;
    padding: 2px 5px !important;
    border-radius: 4px !important;
    border: 1px solid transparent !important;
    background: transparent !important;
    font-family: SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace !important;
    font-size: 11px !important;
    line-height: 1.25 !important;
    cursor: pointer !important;
    transition: border-color 0.15s ease, background 0.15s ease, box-shadow 0.15s ease !important;
    box-sizing: border-box !important;
    user-select: none !important;
  }
  .subconv-code-cell:hover {
    border: 1px solid rgba(125, 125, 125, 0.35) !important;
    background: rgba(125, 125, 125, 0.12) !important;
    box-shadow: 0 1px 4px rgba(0, 0, 0, 0.15) !important;
  }

  @keyframes subconvCellGhost {
    0% { transform: scale(1); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7); }
    20% { transform: scale(1.04); text-shadow: -4px 0 3px rgba(59, 130, 246, 0.95), 4px 0 3px rgba(16, 185, 129, 0.95); box-shadow: -3px 0 0 1px rgba(59, 130, 246, 0.6), 3px 0 0 1px rgba(16, 185, 129, 0.6); }
    45% { transform: scale(1.03); text-shadow: -5px 0 5px rgba(59, 130, 246, 0.8), 5px 0 5px rgba(16, 185, 129, 0.8); box-shadow: 0 0 14px rgba(16, 185, 129, 0.65); }
    70% { transform: scale(1.01); text-shadow: -2px 0 2px rgba(59, 130, 246, 0.5), 2px 0 2px rgba(16, 185, 129, 0.5); }
    100% { transform: scale(1); text-shadow: none; box-shadow: none; }
  }
  .subconv-cell-copied {
    animation: subconvCellGhost 0.6s ease-out !important;
  }

  .subconv-copied-badge {
    position: absolute !important;
    top: -26px !important;
    left: 50% !important;
    transform: translateX(-50%) !important;
    background: #059669 !important;
    color: #ffffff !important;
    font-size: 11px !important;
    font-weight: 600 !important;
    padding: 2px 8px !important;
    border-radius: 4px !important;
    white-space: nowrap !important;
    pointer-events: none !important;
    z-index: 1000 !important;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.3) !important;
    animation: subconvBadgeFloat 1.2s ease-out forwards !important;
  }
  @keyframes subconvBadgeFloat {
    0% { opacity: 0; transform: translate(-50%, 4px) scale(0.85); }
    15% { opacity: 1; transform: translate(-50%, 0) scale(1); }
    75% { opacity: 1; transform: translate(-50%, -2px) scale(1); }
    100% { opacity: 0; transform: translate(-50%, -10px) scale(0.9); }
  }

  .subconv-spin {
    display: inline-block !important;
    animation: subconvSpin 1s linear infinite !important;
  }
  @keyframes subconvSpin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
  }

  /* Кол 1 (URL): комфортный размер без растягивания таблицы */
  .cbi-section-table th:nth-child(1),
  .cbi-section-table td:nth-child(1) {
    min-width: 125px !important;
    max-width: 165px !important;
  }
  .cbi-section-table td:nth-child(1) .subconv-code-cell {
    word-break: break-all !important;
  }

  /* Кол 2 (User-Agent): родной выпадающий список LuCI (cbi-dropdown) с возможностью ввести свой вариант.
     Внешний вид остаётся как в теме OpenWrt, ограничивается только ширина: собственный min-width
     у cbi-dropdown сбрасывается, иначе колонка раздувается до ~200px. */
  .cbi-section-table th:nth-child(2),
  .cbi-section-table td:nth-child(2) {
    width: 110px !important;
    min-width: 100px !important;
    max-width: 115px !important;
    overflow: visible !important;
  }
  .cbi-section-table td:nth-child(2) cbi-dropdown,
  .cbi-section-table td:nth-child(2) .cbi-dropdown {
    width: 100% !important;
    min-width: 0 !important;
    max-width: 110px !important;
    box-sizing: border-box !important;
  }
  /* Закрытый список: длинный текст обрезается, а не растягивает поле */
  .cbi-section-table td:nth-child(2) cbi-dropdown:not([open]) > ul,
  .cbi-section-table td:nth-child(2) .cbi-dropdown:not([open]) > ul {
    min-width: 0 !important;
  }
  .cbi-section-table td:nth-child(2) cbi-dropdown:not([open]) > ul > li,
  .cbi-section-table td:nth-child(2) .cbi-dropdown:not([open]) > ul > li {
    min-width: 0 !important;
    max-width: 100% !important;
    overflow: hidden !important;
    text-overflow: ellipsis !important;
    white-space: nowrap !important;
  }
  /* Открытый список: по ширине самого длинного пункта, чтобы названия читались полностью */
  .cbi-section-table td:nth-child(2) cbi-dropdown[open] > ul:not(.preview),
  .cbi-section-table td:nth-child(2) .cbi-dropdown[open] > ul:not(.preview) {
    min-width: 100% !important;
    width: max-content !important;
    max-width: 260px !important;
  }

  /* Кол 3 (HWID): комфортная ширина для переноса по дефису без сплющивания букв */
  .cbi-section-table th:nth-child(3),
  .cbi-section-table td:nth-child(3) {
    width: 125px !important;
    min-width: 115px !important;
    max-width: 135px !important;
    font-size: 11px !important;
    line-height: 1.25 !important;
  }
  .cbi-section-table td:nth-child(3) .subconv-code-cell {
    overflow-wrap: break-word !important;
    word-break: break-word !important;
  }

  /* Кол 4 (OS): достаточная ширина для 2 строк */
  .cbi-section-table th:nth-child(4),
  .cbi-section-table td:nth-child(4) {
    width: 85px !important;
    min-width: 80px !important;
    max-width: 95px !important;
    font-size: 11px !important;
    line-height: 1.25 !important;
  }
  .cbi-section-table td:nth-child(4) .subconv-code-cell {
    white-space: normal !important;
    word-break: normal !important;
  }

  /* Кол 5 (Модель): достаточная ширина для названия устройства */
  .cbi-section-table th:nth-child(5),
  .cbi-section-table td:nth-child(5) {
    width: 95px !important;
    min-width: 90px !important;
    max-width: 110px !important;
    font-size: 11px !important;
    line-height: 1.25 !important;
  }
  .cbi-section-table td:nth-child(5) .subconv-code-cell {
    white-space: normal !important;
    word-break: normal !important;
  }

  /* Кол 6 (Обновление): компактный drop-down интервала Cron */
  .cbi-section-table th:nth-child(6),
  .cbi-section-table td:nth-child(6) {
    width: 85px !important;
    min-width: 80px !important;
    max-width: 90px !important;
  }
  .cbi-section-table td:nth-child(6) select,
  .cbi-section-table td:nth-child(6) .cbi-input-select,
  .cbi-section-table td:nth-child(6) cbi-dropdown,
  .cbi-section-table td:nth-child(6) .cbi-dropdown {
    width: 100% !important;
    max-width: 85px !important;
    min-width: 75px !important;
    height: 28px !important;
    line-height: 20px !important;
    font-size: 11px !important;
    padding: 2px 4px !important;
    box-sizing: border-box !important;
    border-radius: 4px !important;
  }

  /* Кол 7 (Тип выдачи): четкий компактный статус */
  .cbi-section-table th:nth-child(7),
  .cbi-section-table td:nth-child(7) {
    width: 90px !important;
    min-width: 80px !important;
    max-width: 95px !important;
    font-size: 11px !important;
    line-height: 1.25 !important;
  }

  /* Кол 8: Данные подписки (строго 3 строки без раздувания ширины) */
  .cbi-section-table th:nth-child(8),
  .cbi-section-table td:nth-child(8) {
    width: 175px !important;
    min-width: 165px !important;
    white-space: nowrap !important;
  }

  /* 6. Кнопки действий справа: компактные 28x28 */
  .cbi-section-table th:nth-last-child(-n+5),
  .cbi-section-table td:nth-last-child(-n+5) {
    width: 32px !important;
    min-width: 32px !important;
    max-width: 34px !important;
    padding: 3px 1px !important;
    text-align: center !important;
    white-space: nowrap !important;
  }
  .cbi-section-table td:nth-last-child(-n+5) .cbi-button,
  .cbi-section-table td:nth-last-child(-n+5) a.cbi-button {
    margin: 0 !important;
    padding: 3px 6px !important;
    font-size: 13px !important;
    min-width: 28px !important;
    width: 28px !important;
    height: 28px !important;
    line-height: 20px !important;
    display: inline-flex !important;
    align-items: center !important;
    justify-content: center !important;
    box-sizing: border-box !important;
  }

  /* 7. Скрываем дублирующую строку кнопки очистки логов и нижнюю панель действий LuCI */
  div[id*="_clear_log"]:not(button):not(input) {
    display: none !important;
  }
  .cbi-page-actions {
    display: none !important;
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

  /* 9. ЖУРНАЛ ОТЛАДКИ: 100% ширина, идеально выровненная со всеми блоками страницы */
  #cbi-subconv-global,
  fieldset.cbi-section:has(#subconv-debug-log),
  fieldset.cbi-section:has(textarea) {
    width: 100% !important;
    max-width: 100% !important;
    min-width: 100% !important;
    box-sizing: border-box !important;
    margin-left: 0 !important;
    margin-right: 0 !important;
    padding-left: 0 !important;
    padding-right: 0 !important;
  }
  fieldset.cbi-section:has(#subconv-debug-log) .cbi-section-node,
  fieldset.cbi-section:has(#subconv-debug-log) .cbi-value,
  fieldset.cbi-section:has(#subconv-debug-log) .cbi-value-field,
  .cbi-section:has(#subconv-debug-log) .cbi-value-field,
  #cbi-subconv-global .cbi-section-node,
  #cbi-subconv-global .cbi-value,
  #cbi-subconv-global .cbi-value-field {
    width: 100% !important;
    max-width: 100% !important;
    min-width: 100% !important;
    margin-left: 0 !important;
    margin-right: 0 !important;
    padding-left: 0 !important;
    padding-right: 0 !important;
    box-sizing: border-box !important;
    display: block !important;
  }
  fieldset.cbi-section:has(#subconv-debug-log) .cbi-value-title {
    display: none !important;
  }
  #subconv-debug-log {
    width: 100% !important;
    max-width: 100% !important;
    min-width: 100% !important;
    box-sizing: border-box !important;
    display: block !important;
    height: 350px !important;
    background: #1a1b26 !important;
    color: #a9b1d6 !important;
    font-family: monospace !important;
    font-size: 13px !important;
    padding: 10px !important;
    border: 1px solid #333 !important;
    margin-top: 10px !important;
    border-radius: 4px !important;
  }
</style>]===]

local JS_TWEAKS_PART1 = [===[<script>
    function fallbackCopy(text, cb) {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); } catch(e){}
        document.body.removeChild(ta);
        if (cb) cb();
    }

    function copyCell(el, text) {
        if (!text) text = el.getAttribute('data-copy') || el.innerText;
        if (!text) return;

        var triggerFeedback = function() {
            el.classList.remove('subconv-cell-copied');
            void el.offsetWidth;
            el.classList.add('subconv-cell-copied');
            setTimeout(function() {
                el.classList.remove('subconv-cell-copied');
            }, 650);

            var oldBadge = el.querySelector('.subconv-copied-badge');
            if (oldBadge) oldBadge.remove();

            var badge = document.createElement('span');
            badge.className = 'subconv-copied-badge';
            badge.innerText = 'Скопировано! ✅';
            el.appendChild(badge);
            setTimeout(function() {
                if (badge && badge.parentNode) badge.parentNode.removeChild(badge);
            }, 1200);
        };

        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(triggerFeedback).catch(function() {
                fallbackCopy(text, triggerFeedback);
            });
        } else {
            fallbackCopy(text, triggerFeedback);
        }
    }

    function copySubLink(btn, subId) {
        var url = 'http://127.0.0.1/' + subId + '.txt';
        copyCell(btn, url);
        btn.innerText = '✅';
        setTimeout(function() { btn.innerText = '🔗'; }, 1500);
    }

    function checkPluginVersion() {
        var btnCheck = document.getElementById('btn-check-ver');
        if(!btnCheck) return;
        btnCheck.innerText = 'Проверка...';
        btnCheck.disabled = true;
        fetch('https://api.github.com/repos/asimoneo/subconv/commits/main', {cache: 'no-store'})
            .then(res => res.json())
            .then(data => {
                if(!data.sha) throw new Error("No commit");
                return fetch('https://raw.githubusercontent.com/asimoneo/subconv/' + data.sha + '/install.sh', {cache: 'no-store'});
            })
            .then(res => res.text())
            .then(text => {
                var match = text.match(/VERSION=["']([^"']+)["']/);
                if(match) {
                    var remote = match[1];
                    var current = ']===]

local JS_TWEAKS_PART2 = [===[';
                    var verText = document.getElementById('plugin-ver-text');
                    if(remote !== current) {
                        verText.innerHTML = 'v' + current + ' &rarr; <b style="color:#ff9800;">v' + remote + '</b>';
                        var btnUpd = document.getElementById('btn-do-update');
                        if(btnUpd) btnUpd.style.display = 'inline-block';
                    } else {
                        verText.innerHTML = 'v' + current + ' (Актуально)';
                    }
                } else {
                    throw new Error("No VERSION tag");
                }
            })
            .catch(e => {
                alert('Ошибка проверки версии: ' + e.message);
            })
            .finally(() => {
                btnCheck.innerText = 'Проверить обновления';
                btnCheck.disabled = false;
            });
    }

    function doPluginUpdate() {
        var hiddenBtn = document.querySelector('#subconv_self_update_btn');
        if(hiddenBtn) {
            document.getElementById('btn-do-update').innerText = 'Обновление...';
            document.getElementById('btn-do-update').disabled = true;
            hiddenBtn.click();
        } else {
            alert('Скрытая кнопка обновления не найдена в DOM');
        }
    }

    // Асинхронное получение свежих строк журнала отладки без перезагрузки страницы
    function refreshDebugLog() {
        var logEl = document.getElementById('subconv-debug-log');
        if (!logEl) return;
        fetch('/subconv_debug.txt?_=' + Date.now(), { cache: 'no-store' })
            .then(function(res) {
                if (res.ok) return res.text();
                throw new Error('Not found');
            })
            .then(function(text) {
                if (text && logEl.value !== text) {
                    var wasAtBottom = (logEl.scrollHeight - logEl.clientHeight <= logEl.scrollTop + 60);
                    logEl.value = text;
                    if (wasAtBottom) {
                        logEl.scrollTop = logEl.scrollHeight;
                    }
                }
            })
            .catch(function() {});
    }

    function initHeaderAndSections() {
        var subHdr = null;
        var logHdr = null;

        document.querySelectorAll('h3, legend').forEach(function(h) {
            if (h.innerText && h.innerText.indexOf('Добавить новую подписку') !== -1) {
                h.style.setProperty('display', 'none', 'important');
                h.remove();
            }
            if (h.innerText && h.innerText.indexOf('Активные подписки') !== -1) subHdr = h;
            if (h.innerText && h.innerText.indexOf('Журнал отладки') !== -1) logHdr = h;
        });

        var addSection = document.querySelector('fieldset:has([name="cbid.subconv.add.sub_id"])') ||
                         document.querySelector('#cbi-subconv-add:not(:has(textarea))');

        var decryptBtn = document.querySelector('[name*="_dl_decrypt"]');
        if (decryptBtn && subHdr) {
            var decryptRow = decryptBtn.closest('.cbi-value');
            if (decryptRow && decryptRow.parentNode !== subHdr) {
                decryptRow.id = 'subconv-decrypt-bar';
                subHdr.style.display = 'flex';
                subHdr.style.alignItems = 'center';
                subHdr.style.flexWrap = 'wrap';
                subHdr.style.gap = '12px';
                subHdr.appendChild(decryptRow);
            }
        }

        var btnClear = document.querySelector('[name*="_clear_log"]');
        if (logHdr && btnClear) {
            var clearRow = btnClear.closest('.cbi-value') || document.querySelector('div[id*="_clear_log"]');
            if (clearRow && clearRow !== btnClear) clearRow.style.setProperty('display', 'none', 'important');
            if (btnClear.parentNode !== logHdr) {
                logHdr.style.display = 'flex';
                logHdr.style.alignItems = 'center';
                logHdr.style.gap = '10px';
                btnClear.style.cssText = 'margin: 0; font-size: 12px; padding: 3px 10px; height: 26px; line-height: 18px; cursor: pointer; vertical-align: middle;';
                logHdr.appendChild(btnClear);

                var btnRefresh = document.getElementById('btn-refresh-log');
                if (!btnRefresh) {
                    btnRefresh = document.createElement('button');
                    btnRefresh.type = 'button';
                    btnRefresh.id = 'btn-refresh-log';
                    btnRefresh.className = 'cbi-button cbi-button-apply';
                    btnRefresh.style.cssText = 'margin: 0; font-size: 12px; padding: 3px 10px; height: 26px; line-height: 18px; cursor: pointer; vertical-align: middle;';
                    btnRefresh.innerText = '🔄 Обновить лог';
                    btnRefresh.onclick = function() {
                        btnRefresh.innerText = '🔄...';
                        refreshDebugLog();
                        setTimeout(function() { btnRefresh.innerText = '🔄 Обновить лог'; }, 600);
                    };
                    logHdr.appendChild(btnRefresh);
                }
            }
        }

        if (addSection && !addSection.dataset.spoilerInit) {
            addSection.dataset.spoilerInit = 'true';
            addSection.classList.add('subconv-add-section');

            var btnToggle = document.getElementById('btn-toggle-add-form');
            if (!btnToggle) {
                btnToggle = document.createElement('button');
                btnToggle.type = 'button';
                btnToggle.id = 'btn-toggle-add-form';
                btnToggle.style.cssText = 'background: #059669; border: 1px solid #10b981; color: #ffffff; border-radius: 4px; padding: 4px 14px; font-size: 13px; height: 30px; line-height: 20px; margin-left: 12px; font-weight: 500; cursor: pointer; display: inline-flex; align-items: center; gap: 6px; vertical-align: middle; box-sizing: border-box; transition: background 0.2s;';
                
                btnToggle.onmouseenter = function() { btnToggle.style.background = '#10b981'; };
                btnToggle.onmouseleave = function() { btnToggle.style.background = '#059669'; };

                var btnCheck = document.getElementById('btn-check-ver');
                if (btnCheck && btnCheck.parentNode) {
                    btnCheck.parentNode.insertBefore(btnToggle, btnCheck.nextSibling);
                }
            }

            function updateFormVisibility() {
                var isExp = addSection.classList.contains('expanded');
                if (btnToggle) {
                    btnToggle.innerHTML = (isExp ? '▼' : '▶') + ' Добавить новую подписку';
                }
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

        document.querySelectorAll('.cbi-section-table tbody tr, .cbi-section-table tr.cbi-section-table-row').forEach(function(row) {
            [1, 3, 4, 5].forEach(function(colIdx) {
                var cell = row.querySelector('td:nth-child(' + colIdx + ')');
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

        var addSection = document.querySelector('fieldset:has([name="cbid.subconv.add.sub_id"])') ||
                         document.querySelector('#cbi-subconv-add:not(:has(textarea))');
        if (addSection) {
            addSection.querySelectorAll('.cbi-value').forEach(function(el) {
                if (el.id === 'subconv-decrypt-bar' || el.id.indexOf('_clear_log') !== -1 || el.querySelector('textarea')) return;
                var field = el.querySelector('.cbi-value-field');
                var desc = el.querySelector('.cbi-value-description');
                if (field) {
                    field.style.setProperty('display', 'flex', 'important');
                    field.style.setProperty('flex-direction', 'row', 'important');
                    field.style.setProperty('align-items', 'center', 'important');
                    field.style.gap = '15px';
                    field.style.setProperty('flex-wrap', 'nowrap', 'important');

                    if (desc) {
                        field.appendChild(desc);
                        desc.style.setProperty('margin', '0', 'important');
                        desc.style.setProperty('opacity', '0.8', 'important');
                        desc.style.setProperty('font-size', '12px', 'important');
                        desc.style.setProperty('white-space', 'nowrap', 'important');
                    }

                    var ctrl = field.querySelector('input:not(.cbi-button), select, .cbi-dropdown, cbi-dropdown') || field.firstElementChild;
                    if (ctrl && !ctrl.classList.contains('cbi-button')) {
                        ctrl.style.setProperty('width', '250px', 'important');
                        ctrl.style.setProperty('max-width', '250px', 'important');
                        ctrl.style.setProperty('min-width', '250px', 'important');
                        ctrl.style.setProperty('flex', '0 0 250px', 'important');
                        ctrl.style.setProperty('box-sizing', 'border-box', 'important');
                    }
                }
            });
        }
    }

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

        document.querySelectorAll('button[onclick*="triggerSubUpdate"]').forEach(function(b) {
            var m = b.getAttribute('onclick').match(/triggerSubUpdate\(this,\s*'([^']+)'\)/);
            if (m && m[1]) {
                var sId = m[1];
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
        var title = document.querySelector('h2');
        if(title && title.innerText.includes('Subconv')) {
            title.innerHTML = ']===]

local JS_TWEAKS_PART3 = [===[';
        }
        alignFormAndTable();
        initStatusWatcher();
    }, 50);

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
    return CSS_TWEAKS .. JS_TWEAKS_PART1 .. current_ver .. JS_TWEAKS_PART2 .. (title_html:gsub("'", "\\'")) .. JS_TWEAKS_PART3
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

    if new_url:match("%s") then
        m.message = "Ошибка: URL подписки не должен содержать пробелы и переносы строк!"
        return
    end

    -- Проверка протокола и формата URL: поддерживаются http://, https://, happ://, v2raytun://
    local is_http = new_url:match("^https?://[%w%.%-%_]+%S*")
    local is_happ = new_url:match("^happ://%S+")
    local is_v2t  = new_url:match("^v2raytun://%S+")
    if not (is_http or is_happ or is_v2t) then
        m.message = "Ошибка: Некорректный URL подписки! Ссылка должна начинаться с http://, https://, happ:// или v2raytun://"
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

-- Кол 5: Model
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
interval_list.rmempty = false

-- Вспомогательная функция форматирования данных подписки
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
            local days_left = has_exp and math.max(0, math.floor((exp - now) / 86400)) or nil

            local d_str = nil
            if has_exp then
                local ld, lt = days_left % 10, days_left % 100
                if lt >= 11 and lt <= 19 then d_str = days_left .. " дней"
                elseif ld == 1 then d_str = days_left .. " день"
                elseif ld >= 2 and ld <= 4 then d_str = days_left .. " дня"
                else d_str = days_left .. " дней" end
            end

            local inf_icon = [[<span style="font-size: 20px; font-weight: bold; line-height: 1; vertical-align: -2px; margin-right: 4px; display: inline-block;">∞</span>]]

            if total > 0 then
                local left_b = math.max(0, total - used)
                l2 = string.format([[<div style="font-size: 11px; opacity: 0.9; margin-top: 2px; white-space: nowrap;">%s / %s до %s</div>]], fmt_b(used), fmt_b(total), exp_date)
                if is_expired then
                    l3 = [[<div style="font-size: 11px; color: #ff5555; font-weight: bold; margin-top: 1px; white-space: nowrap;">Срок истёк</div>]]
                elseif left_b <= 0 then
                    l3 = [[<div style="font-size: 11px; color: #ff5555; font-weight: bold; margin-top: 1px; white-space: nowrap;">Трафик исчерпан</div>]]
                elseif has_exp then
                    if days_left == 0 then
                        l3 = string.format([[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Осталось: %s (истекает сегодня)</div>]], fmt_b(left_b))
                    else
                        l3 = string.format([[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Осталось: %s на %s</div>]], fmt_b(left_b), d_str)
                    end
                else
                    l3 = string.format([[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Осталось: %s</div>]], fmt_b(left_b))
                end
            else
                if has_exp then
                    l2 = string.format([[<div style="font-size: 11px; opacity: 0.9; margin-top: 2px; white-space: nowrap;">%sдо %s</div>]], inf_icon, exp_date)
                    if is_expired then
                        l3 = [[<div style="font-size: 11px; color: #ff5555; font-weight: bold; margin-top: 1px; white-space: nowrap;">Срок истёк</div>]]
                    elseif days_left == 0 then
                        l3 = [[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Истекает сегодня</div>]]
                    else
                        l3 = string.format([[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Осталось: %s</div>]], d_str)
                    end
                else
                    l2 = string.format([[<div style="font-size: 11px; opacity: 0.9; margin-top: 2px; white-space: nowrap;">%sбез ограничений</div>]], inf_icon)
                    l3 = [[<div style="font-size: 11px; opacity: 0.8; margin-top: 1px; white-space: nowrap;">Бессрочно</div>]]
                end
            end
        end
    else
        l2 = [[<div style="font-size: 11px; opacity: 0.5; margin-top: 2px; white-space: nowrap;">(нет данных)</div>]]
    end
    return string.format([[<div style="line-height: 1.3; white-space: nowrap;"><div style="font-size: 13px; font-weight: bold;">%s</div>%s%s</div>]], id, l2, l3)
end

-- Кол 7: Тип выдачи
local type_opt = s_list:option(DummyValue, "last_type", translate("Тип выдачи"))
type_opt.rawhtml = true
function type_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "last_type") or "Ожидание..."
    if val == "Обновление..." then
        return string.format('<span class="subconv-status-cell subconv-status-updating" data-sub="%s" style="display:inline-flex; align-items:center; gap:4px; font-weight:500; color:#2563eb;"><span class="subconv-spin">🔄</span> Обновление...</span>', section)
    end
    return string.format('<span class="subconv-status-cell" data-sub="%s">%s</span>', section, val)
end

-- Кол 8: Данные подписки
local link_opt = s_list:option(DummyValue, "_link", translate("Данные подписки"))
link_opt.rawhtml = true
function link_opt.cfgvalue(self, section)
    local uinfo = uci:get("subconv", section, "userinfo")
    return string.format('<span class="subconv-info-cell" data-sub="%s">%s</span>', section, format_sub_info(section, uinfo))
end

-- Кнопка [ 🔗 ]: Скопировать ссылку
local btn_copy_link = s_list:option(DummyValue, "_copy_link", translate(" "))
btn_copy_link.rawhtml = true
function btn_copy_link.cfgvalue(self, section)
    return string.format([[<button type="button" onclick="copySubLink(this, '%s')" class="cbi-button cbi-button-neutral" style="padding: 3px 6px; font-size: 13px; margin: 0; min-width: 28px; width: 28px; height: 28px; line-height: 20px; display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box;" title="Скопировать ссылку http://127.0.0.1/%s.txt">🔗</button>]], section, section)
end

-- Кнопка [ 🗒️ ]: Открыть готовый файл
local btn_open_txt = s_list:option(DummyValue, "_open_txt", translate(" "))
btn_open_txt.rawhtml = true
function btn_open_txt.cfgvalue(self, section)
    return string.format([[<a href="/%s.txt" target="_blank" class="cbi-button cbi-button-neutral" style="padding: 3px 6px; font-size: 13px; margin: 0; min-width: 28px; width: 28px; height: 28px; line-height: 20px; text-decoration: none; display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box;" title="Открыть готовый файл">🗒️</a>]], section)
end

-- Кнопка [ 💾 ]: Скачать файл
local btn_dl_txt = s_list:option(DummyValue, "_dl_txt", translate(" "))
btn_dl_txt.rawhtml = true
function btn_dl_txt.cfgvalue(self, section)
    return string.format([[<a href="/%s.txt" download="%s.txt" class="cbi-button cbi-button-neutral" style="padding: 3px 6px; font-size: 13px; margin: 0; min-width: 28px; width: 28px; height: 28px; line-height: 20px; text-decoration: none; display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box;" title="Скачать расшифрованный список (.txt)">💾</a>]], section, section)
end

-- Кнопка [ 🔄 ]: Обновить подписку (через AJAX без перезагрузки всей страницы)
local btn_upd_list = s_list:option(DummyValue, "_update", translate(" "))
btn_upd_list.rawhtml = true
function btn_upd_list.cfgvalue(self, section)
    return string.format([[<button type="button" onclick="triggerSubUpdate(this, '%s')" class="cbi-button cbi-button-apply" style="padding: 3px 6px; font-size: 13px; margin: 0; min-width: 28px; width: 28px; height: 28px; line-height: 20px; display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box;" title="Обновить подписку">🔄</button>]], section)
end

-- Кнопка [ 🗑️ ]: Удаление подписки
local btn_del_list = s_list:option(Button, "_delete", translate(" "))
btn_del_list.inputtitle = "🗑️"
btn_del_list.inputstyle = "remove"
function btn_del_list.write(self, section)
    os.execute("rm -f " .. util.shellquote("/www/" .. section .. ".txt"))
    uci:delete("subconv", section)
    uci:commit("subconv")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

-- ------------------------------------------
-- СЕКЦИЯ 3: Журнал отладки (Debug Log)
-- ------------------------------------------
local s_log = m:section(TypedSection, "global", translate("Журнал отладки"))
s_log.anonymous = true
s_log.addremove = false
function s_log.filter(self, section) return section == "add" end

-- Кнопка очистки логов
local btn_clear = s_log:option(Button, "_clear_log", "")
btn_clear.inputtitle = translate("Очистить лог")
btn_clear.inputstyle = "remove"
function btn_clear.write(self, section)
    os.execute("rm -f /www/subconv_debug.txt")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

-- Просмотрщик логов (читает файл /www/subconv_debug.txt)
local log_view = s_log:option(DummyValue, "_logview")
log_view.rawhtml = true
function log_view.cfgvalue(self, section)
    local f = io.open("/www/subconv_debug.txt", "r")
    local content = f and f:read("*all") or "Лог пуст. Нажмите 🔄 на любой подписке."
    if f then f:close() end
    content = content:gsub("<", "&lt;"):gsub(">", "&gt;")
    -- Вывод логов в полноразмерный терминал с автопрокруткой вниз
    return '<textarea id="subconv-debug-log" readonly wrap="off" style="width: 100%; max-width: 100%; min-width: 100%; height: 350px; background: #1a1b26; color: #a9b1d6; font-family: monospace; font-size: 13px; padding: 10px; border: 1px solid #333; margin-top: 10px; box-sizing: border-box; display: block; border-radius: 4px;">' .. content .. '</textarea><script>setTimeout(function(){var l=document.getElementById("subconv-debug-log");if(l){l.scrollTop=l.scrollHeight;}}, 100);</script>'
end

-- ==========================================
-- Системные обработчики и события
-- ==========================================

function m.on_after_commit(self)
    sys.call("/usr/libexec/subconv-cron.sh")
end

if http.formvalue("subconv_self_update") == "1" then
    sys.call("curl -fsSL 'https://raw.githubusercontent.com/asimoneo/subconv/refs/heads/main/install.sh' | sh -s 1 >/dev/null 2>&1 &")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

return m
EOF
sed -i "s/local current_ver = \".*\"/local current_ver = \"$VERSION\"/" /usr/lib/lua/luci/model/cbi/subconv.lua

if [ ! -f /etc/config/subconv ]; then
    echo "config global 'add'" > /etc/config/subconv
elif ! grep -q "config global 'add'" /etc/config/subconv; then
    echo "config global 'add'" >> /etc/config/subconv
fi

rm -rf /tmp/luci-* /tmp/rpcd-* /tmp/state/*
/etc/init.d/rpcd restart
echo "✅ Установка завершена!"
