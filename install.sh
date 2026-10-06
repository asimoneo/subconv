#!/bin/sh

VERSION="0.3.16"
action="${1}"

echo "========================================================="
echo "        Установка Subconv v$VERSION                      "
echo "========================================================="

if [ -z "$action" ]; then
    echo "Выберите действие:"
    echo " 1) Установить / Обновить плагин"
    echo " 2) Полностью УДАЛИТЬ плагин и все его файлы"
    echo "========================================================="
    printf "Ваш выбор [1]: "
    read action
    action=${action:-1}
fi

if [ "$action" = "2" ]; then
    echo "Удаление Subconv..."
    
    if [ -f /etc/config/subconv ]; then
        for sub in $(grep -E "config subscription" /etc/config/subconv | awk -F"'" '{print $2}'); do
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
    /bin/opkg update
    /bin/opkg install curl
fi

mkdir -p /usr/libexec
mkdir -p /usr/lib/lua/luci/model/cbi
mkdir -p /usr/lib/lua/luci/controller
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

-- Функция записи логов отладки
local function log(msg)
    local f_dbg = io.open(debug_file, "a")
    if f_dbg then
        -- Форматируем строку: [Дата] [ID подписки] Сообщение
        f_dbg:write(os.date("%Y-%m-%d %H:%M:%S") .. " [" .. (sub_id or "NONE") .. "] " .. msg .. "\n")
        f_dbg:close()
    end
end

-- Функция сохранения статуса обновления в UCI для отображения в веб-интерфейсе
local function save_status(msg)
    if not sub_id then return end
    local u = require "luci.model.uci".cursor()
    u:set("subconv", sub_id, "last_type", msg)
    local ok = u:commit("subconv")
    if not ok then
        nixio.nanosleep(0, 200000000)
        u:commit("subconv")
    end
    os.remove("/tmp/subconv_status.json")
end

-- Централизованный обработчик ошибок (пишет в лог, обновляет статус и завершает работу)
local function exit_with_error(msg, status_msg)
    log("ОШИБКА: " .. msg)
    if status_msg then save_status(status_msg) end
    os.exit(1)
end

-- Функция маскировки URL (стандарт токенов GitHub / AWS, аналогично таблице)
local function mask_url(val)
    if not val or val == "" then return "" end
    if #val <= 18 then return val end
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
    return prefix .. "••••" .. tail
end

-- Дешифровка проприетарных ссылок happ://crypt с помощью локального Go-бинарника
local function decrypt_happ_url(url)
    local bin_path = "/usr/libexec/happ-decrypt"
    local bin_ver = "unknown"
    if nixio.fs.access(bin_path) then
        local v_handle = io.popen(bin_path .. " --version 2>/dev/null")
        if v_handle then
            bin_ver = v_handle:read("*l") or "unknown"
            v_handle:close()
        end
    end
    log("Обнаружена крипто-ссылка: " .. mask_url(url) .. ". Дешифратор: " .. bin_ver .. "...")

    if not nixio.fs.access(bin_path) then
        exit_with_error("Бинарник дешифратора не найден.", "Нет дешифратора")
    end
    
    -- Вызов бинарника с передачей зашифрованного URL
    local handle = io.popen(bin_path .. " " .. util.shellquote(url) .. " 2>&1")
    local result = handle and handle:read("*all") or ""
    if handle then handle:close() end
    
    -- Парсинг результата (ищем прямую ссылку)
    local decrypted = result:match("Result\r?\n(https?://%S+)") or result:match("Result\r?\n(%S+)")
    
    if decrypted and decrypted:match("^http") then
        log("Успешно расшифровано! Истинный URL: " .. mask_url(decrypted))
        return decrypted
    else
        exit_with_error("Сбой дешифровки: " .. tostring(result):sub(1, 150), "Сбой дешифровки")
    end
end

-- Загрузка списка узлов с сервера провайдера с подменой заголовков (User-Agent, HWID)
local function parse_userinfo(hdr_file)
    local f = io.open(hdr_file, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    os.remove(hdr_file)
    if not content or content == "" then return nil end
    local uinfo_line = content:lower():match("subscription%-userinfo%s*:[^%c]+")
    if not uinfo_line then return nil end
    local upload = tonumber(uinfo_line:match("upload=(%d+)")) or 0
    local download = tonumber(uinfo_line:match("download=(%d+)")) or 0
    local total = tonumber(uinfo_line:match("total=(%d+)")) or 0
    local expire = tonumber(uinfo_line:match("expire=(%d+)")) or 0
    return string.format("%.0f|%.0f|%.0f", upload + download, total, expire)
end

local function fetch_subscription(url, ua, hwid, dev_os, dev_model, hdr_file)
    local cmd = string.format("curl -k -L -s -D %s -w '%%{http_code}' --connect-timeout 10 --max-time 30 -A %s -H %s -H %s -H %s %s",
        util.shellquote(hdr_file),
        util.shellquote(ua),
        util.shellquote("X-HWID: " .. hwid),
        util.shellquote("X-DEVICE-OS: " .. dev_os),
        util.shellquote("X-DEVICE-MODEL: " .. dev_model),
        util.shellquote(url)
    )
    local handle = io.popen(cmd)
    local resp_raw = handle and handle:read("*all") or ""
    if handle then handle:close() end
    return resp_raw
end

local function write_to_file(path, content_data)
    local f_out = io.open(path, "w")
    if f_out then
        f_out:write(content_data)
        f_out:close()
        return true
    end
    return false
end

-- ==========================================
-- Главный процесс
-- ==========================================

log("=== СТАРТ ОБНОВЛЕНИЯ ===")
if not sub_id then os.exit(1) end

-- 1. Считывание настроек подписки из конфигурации роутера (UCI)
uci:load("subconv")
local url = uci:get("subconv", sub_id, "url")
if not url or url == "" then
    exit_with_error("нет URL", "Ошибка: нет URL")
end

local ua = uci:get("subconv", sub_id, "user_agent") or "SubConv/1.0"
local hwid = uci:get("subconv", sub_id, "hwid") or "openwrt-router-default"
local dev_os = uci:get("subconv", sub_id, "device_os") or "OpenWrt"
local dev_model = uci:get("subconv", sub_id, "device_model") or "OpenWrt Router"
local out_path = "/www/" .. sub_id .. ".txt"

-- 2. Если ссылка проприетарная, расшифровываем ее перед загрузкой
if url:match("^happ://") or url:match("^v2raytun://") then
    url = decrypt_happ_url(url)
end

log("Запрос: " .. sub_id .. " (" .. mask_url(url) .. ")")
log("Заголовки: UA=" .. ua .. " | HWID=" .. hwid .. " | OS=" .. dev_os)
log("Отправка запроса к серверу...")

-- 3. Выполняем запрос к серверу провайдера
local hdr_file = "/tmp/sub_headers_" .. (sub_id or "tmp") .. ".tmp"
local resp_raw = fetch_subscription(url, ua, hwid, dev_os, dev_model, hdr_file)
local uinfo_str = parse_userinfo(hdr_file)
if uinfo_str and sub_id then
    local u = require "luci.model.uci".cursor()
    u:set("subconv", sub_id, "userinfo", uinfo_str)
    local ok = u:commit("subconv")
    if not ok then
        nixio.nanosleep(0, 200000000)
        u:commit("subconv")
    end
    log("Тариф (структура): " .. uinfo_str)
end
if not resp_raw or #resp_raw < 3 then
    exit_with_error("Сервер не ответил (сбой сети или таймаут)", "Ошибка сети")
end

-- Отделяем HTTP-код состояния (последние 3 символа из вывода curl) от тела ответа
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

-- Проверяем, является ли ответ "сырым" массивом конфигурации (JSON/YAML)
local is_raw = decoded:match("^%s*{") or decoded:match("^%s*%[") or decoded:match("proxies:")

-- 5. Сохранение полученных узлов в локальный файл для HomeProxy
if is_raw then
    -- Сохраняем сырой конфиг как есть (HomeProxy сам разберется с JSON/YAML, если поддерживает)
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
        -- Убираем пробелы по краям
        line = line:match("^%s*(.-)%s*$")
        -- Если строка похожа на рабочую ссылку — добавляем в массив
        if line and (line:match("://") or line:match("^happ://")) then 
            table.insert(links, line) 
        end
    end

    -- Если ссылки найдены, сохраняем их в файл, доступный встроенному веб-серверу (uhttpd)
    if #links > 0 then
        if write_to_file(out_path, table.concat(links, "\n") .. "\n") then
            log("УСПЕХ: Найдено " .. #links .. " узлов URI")
            save_status(is_b64 and ("Base64 (" .. #links .. ")") or ("Текст (" .. #links .. ")"))
        else
            exit_with_error("Не удалось записать файл " .. out_path, "Ошибка записи")
        end
    else
        -- Если ничего не нашли, логируем начало мусорного ответа
        local snippet = decoded:sub(1, 50):gsub("[%c\n\r]", " ")
        exit_with_error("Узлы не найдены. Начало ответа: " .. snippet, "Пусто (Нет узлов)")
    end
end
EOF
chmod +x /usr/libexec/subconv-update.sh

cat << 'EOF' > /usr/libexec/subconv-cron.sh
#!/bin/sh
# =====================================================================
# Скрипт синхронизации расписания Cron для подписок
# =====================================================================
# Этот скрипт вызывается LuCI при сохранении настроек подписок.
# Он читает параметр interval для каждой подписки и создает записи в /etc/crontabs/root.

. /lib/functions.sh

# Удаляем все старые задачи subconv из crontabs
if [ -f /etc/crontabs/root ]; then
    sed -i '/subconv-update.sh/d' /etc/crontabs/root
fi

# Функция добавления задачи для конкретной подписки
add_cron() {
    local cfg="$1"
    local interval
    config_get interval "$cfg" interval "1440"
    
    # 0 = Отключено
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
        "action": {
            "type": "cbi",
            "path": "subconv"
        },
        "order": 90
    }
}
EOF

cat << 'EOF' > /usr/share/rpcd/acl.d/subconv.json
{
    "luci-app-subconv": {
        "description": "Grant UCI access for Subconv",
        "read": {
            "uci": [ "subconv" ],
            "file": {
                "/www/*.txt": [ "read" ],
                "/www/subconv_debug.txt": [ "read" ]
            }
        },
        "write": {
            "uci": [ "subconv" ]
        }
    }
}
EOF

cat << 'EOF' > /usr/lib/lua/luci/controller/subconv.lua
module("luci.controller.subconv", package.seeall)
function index()
    entry({"admin", "services", "subconv"}, cbi("subconv"), _("Subconv"), 90).dependent = true
    entry({"admin", "services", "subconv", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "subconv", "update_ajax"}, call("action_update_ajax")).leaf = true
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
        local lt = (s.last_type or ""):gsub('\\', '\\\\'):gsub('"', '\\"')
        local ui = (s.userinfo or ""):gsub('\\', '\\\\'):gsub('"', '\\"')
        local info_h = format_sub_info(id, s.userinfo):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\r?\n', '')
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
        local cmds = {}
        uci:foreach("subconv", "subscription", function(s)
            local id = s[".name"]
            uci:set("subconv", id, "last_type", "Обновление...")
            table.insert(cmds, "/usr/libexec/subconv-update.sh " .. util.shellquote(id))
        end)
        uci:commit("subconv")
        if #cmds > 0 then
            local full_cmd = "(" .. table.concat(cmds, "; ") .. ") >/dev/null 2>&1 &"
            sys.call(full_cmd)
        end
        http.prepare_content("application/json")
        http.write('{"status":"ok","all":true}')
        return
    end

    if sub and sub ~= "" then
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
EOF

cat << 'EOF' > /usr/lib/lua/luci/model/cbi/subconv.lua
-- =====================================================================
-- LuCI Модель управления сервисом Subconv (CBI)
-- =====================================================================

local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local sys = require "luci.sys"
local http = require "luci.http"
local dsp = require "luci.dispatcher"
local nixio = require "nixio"

-- Текущая версия плагина (обновляется скриптом install.sh)
local current_ver = "0.3.16"

-- ==========================================
-- Логика скачивания дешифратора happ-decrypt
-- ==========================================

-- Проверяем наличие установленного бинарника и его версию
local is_decrypt_installed = nixio.fs.access("/usr/libexec/happ-decrypt")
local decrypt_ver_text = ""
if is_decrypt_installed then
    local v_handle = io.popen("/usr/libexec/happ-decrypt --version 2>/dev/null")
    if v_handle then
        decrypt_ver_text = v_handle:read("*l") or ""
        v_handle:close()
    end
end

-- Обработка клика по кнопке: "Скачать дешифратор"
if http.formvalue("download_decrypt") == "1" then
    -- Определяем архитектуру процессора роутера
    local raw_arch = sys.exec("opkg print-architecture | awk 'NR>1 {print $2}' | head -n 1"):gsub("%s+", "")
    if raw_arch == "" then
        raw_arch = sys.exec("uname -m"):gsub("%s+", "")
    end
    
    -- Сопоставляем архитектуру OpenWrt с релизами Go
    local go_arch = "mipsle-softfloat"
    if raw_arch:match("x86_64") or raw_arch:match("amd64") then
        go_arch = "x86_64"
    elseif raw_arch:match("aarch64") or raw_arch:match("arm64") then
        go_arch = "arm64"
    elseif raw_arch:match("arm") then
        go_arch = "armv7"
    elseif raw_arch:match("mips_24kc") then
        go_arch = "mips-softfloat"
    elseif raw_arch:match("mipsel_24kc") then
        go_arch = "mipsle-softfloat"
    end
    
    -- Формируем URL для скачивания последней версии с GitHub
    local dl_url = "https://github.com/asimoneo/subconv/releases/latest/download/happ-decrypt-linux-" .. go_arch
    
    -- Скачиваем бинарник и делаем исполняемым
    sys.call(string.format("curl -L -k -s -o /usr/libexec/happ-decrypt %s && chmod +x /usr/libexec/happ-decrypt", util.shellquote(dl_url)))
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

-- ==========================================
-- Верстка заголовка со статусом версий
-- ==========================================

local title_html = string.format([[<a href="https://github.com/asimoneo/subconv" target="_blank" style="text-decoration:none; color:inherit; border-bottom: 1px dashed;">Subconv</a> <span style="font-size: 14px; opacity: 0.6; font-weight: normal; margin-left: 8px;" id="plugin-ver-text">v%s</span> <button type="button" class="cbi-button" style="margin-left: 10px; font-size: 12px; padding: 2px 6px;" id="btn-check-ver" onclick="checkPluginVersion()">Проверить обновления</button><button type="button" class="cbi-button cbi-button-apply" style="margin-left: 5px; font-size: 12px; padding: 2px 6px; display: none;" id="btn-do-update" onclick="doPluginUpdate()">Обновить плагин</button>]], current_ver)


local CSS_TWEAKS = [===[<style>
  /* 1. Выпадающая форма добавления (0.8с) с плавной сменой стрелки */
  .subconv-add-section.expanded,
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]).expanded {
    max-height: 900px !important;
    opacity: 1 !important;
    margin-top: 15px !important;
    margin-bottom: 25px !important;
    padding-top: 15px !important;
    padding-bottom: 20px !important;
    pointer-events: auto !important;
  }
  .subconv-add-section,
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) {
    max-height: 0 !important;
    opacity: 0 !important;
    overflow: hidden !important;
    margin: 0 !important;
    padding-top: 0 !important;
    padding-bottom: 0 !important;
    border-top: none !important;
    border-bottom: none !important;
    pointer-events: none !important;
    transition: max-height 0.8s cubic-bezier(0.4, 0, 0.2, 1), 
                opacity 0.6s ease-in-out, 
                margin 0.6s ease, 
                padding 0.6s ease !important;
  }

  /* Скрываем дублирующийся легенд формы внутри спойлера */
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) > legend,
  .subconv-add-section > legend {
    display: none !important;
  }

  /* 2. Поля формы добавления: лейблы 150px, поля 250px, подсказки справа */
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value,
  .subconv-add-section .cbi-value {
    display: flex !important;
    align-items: center !important;
    margin-bottom: 10px !important;
    padding: 0 !important;
    border: none !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value-title,
  .subconv-add-section .cbi-value-title {
    width: 150px !important;
    min-width: 150px !important;
    max-width: 150px !important;
    text-align: right !important;
    padding-right: 15px !important;
    font-size: 13px !important;
    box-sizing: border-box !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) .cbi-value-field,
  .subconv-add-section .cbi-value-field {
    display: flex !important;
    flex-direction: row !important;
    align-items: center !important;
    flex: 1 1 auto !important;
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

  /* 3. Кнопки проверки версии в шапке */
  #btn-check-ver, #btn-do-update {
    font-size: 13px !important;
    padding: 4px 10px !important;
    height: 30px !important;
    line-height: 20px !important;
    box-sizing: border-box !important;
    vertical-align: middle !important;
  }

  /* 4. Бейджик дешифратора справа от заголовка Активные подписки */
  #subconv-decrypt-bar {
    display: inline-flex !important;
    align-items: center !important;
    margin: 0 0 0 16px !important;
    padding: 2px 10px !important;
    font-size: 12px !important;
    background: rgba(255, 255, 255, 0.05) !important;
    border-radius: 4px !important;
    border: 1px solid rgba(255, 255, 255, 0.1) !important;
    vertical-align: middle !important;
    width: auto !important;
    height: 28px !important;
    box-sizing: border-box !important;
  }
  #subconv-decrypt-bar .cbi-value-title {
    width: auto !important;
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

  /* Интерактивные кликабельные поля (URL, HWID, OS, Модель): обводка и фон только при :hover */
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
    transition: background-color 0.15s ease, border-color 0.15s ease, transform 0.1s ease !important;
    user-select: all !important;
    box-sizing: border-box !important;
  }
  .subconv-code-cell:hover {
    background: rgba(255, 255, 255, 0.08) !important;
    border-color: rgba(255, 255, 255, 0.25) !important;
  }

  /* Анимация хроматического раздвоения при клике на ячейку */
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

  /* Всплывающий бейдж "Скопировано! ✅" над ячейкой */
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

  /* Кол 2 (User-Agent Drop-down): строгие 105-115px нативный OpenWrt cbi-dropdown */
  .cbi-section-table th:nth-child(2),
  .cbi-section-table td:nth-child(2) {
    width: 110px !important;
    min-width: 100px !important;
    max-width: 115px !important;
    overflow: visible !important;
  }
  .cbi-section-table td:nth-child(2) select,
  .cbi-section-table td:nth-child(2) > input.cbi-input-text,
  .cbi-section-table td:nth-child(2) cbi-dropdown,
  .cbi-section-table td:nth-child(2) .cbi-dropdown {
    width: 100% !important;
    max-width: 110px !important;
    min-width: 95px !important;
    font-size: 11px !important;
    box-sizing: border-box !important;
  }
  .cbi-section-table td:nth-child(2) cbi-dropdown ul.preview,
  .cbi-section-table td:nth-child(2) .cbi-dropdown ul.preview {
    font-size: 11px !important;
    min-height: 26px !important;
    line-height: 18px !important;
    box-sizing: border-box !important;
  }
  .cbi-section-table td:nth-child(2) cbi-dropdown ul.preview > li,
  .cbi-section-table td:nth-child(2) .cbi-dropdown ul.preview > li {
    font-size: 11px !important;
    padding: 2px 4px !important;
    line-height: 20px !important;
  }
  .cbi-section-table td:nth-child(2) cbi-dropdown[open],
  .cbi-section-table td:nth-child(2) .cbi-dropdown[open] {
    position: relative !important;
    z-index: 9999 !important;
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
    overflow: visible !important;
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
  .cbi-section-table td:nth-child(6) cbi-dropdown ul.preview,
  .cbi-section-table td:nth-child(6) .cbi-dropdown ul.preview {
    font-size: 11px !important;
    min-height: 26px !important;
    line-height: 18px !important;
    box-sizing: border-box !important;
  }
  .cbi-section-table td:nth-child(6) cbi-dropdown ul.preview > li,
  .cbi-section-table td:nth-child(6) .cbi-dropdown ul.preview > li {
    font-size: 11px !important;
    padding: 2px 4px !important;
    line-height: 20px !important;
  }
  .cbi-section-table td:nth-child(6) cbi-dropdown[open],
  .cbi-section-table td:nth-child(6) .cbi-dropdown[open] {
    position: relative !important;
    z-index: 9999 !important;
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

  /* 6. Кнопки действий справа: компактные аккуратные 28x28 */
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
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) div[id*="_add"],
  .subconv-add-section div[id*="_add"] {
    display: flex !important;
    justify-content: center !important;
    align-items: center !important;
    margin-top: 22px !important;
    margin-bottom: 6px !important;
    padding: 0 !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) div[id*="_add"] .cbi-value-title,
  .subconv-add-section div[id*="_add"] .cbi-value-title {
    display: none !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) div[id*="_add"] .cbi-value-field,
  .subconv-add-section div[id*="_add"] .cbi-value-field {
    display: flex !important;
    justify-content: center !important;
    align-items: center !important;
    margin: 0 !important;
    padding: 0 !important;
  }
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) div[id*="_add"] .cbi-button,
  .subconv-add-section div[id*="_add"] .cbi-button {
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
  fieldset.cbi-section:has([name="cbid.subconv.add.sub_id"]) div[id*="_add"] .cbi-button:hover,
  .subconv-add-section div[id*="_add"] .cbi-button:hover {
    background: #10b981 !important;
    box-shadow: 0 4px 12px rgba(16, 185, 129, 0.4) !important;
    transform: translateY(-1px) !important;
  }

  /* 9. Полноразмерный Журнал отладки на всю ширину страницы */
  fieldset.cbi-section:has(#subconv-debug-log),
  .cbi-section:has(#subconv-debug-log) {
    width: 100% !important;
    max-width: 100% !important;
    box-sizing: border-box !important;
  }
  fieldset.cbi-section:has(#subconv-debug-log) .cbi-section-node,
  .cbi-section:has(#subconv-debug-log) .cbi-section-node {
    width: 100% !important;
    max-width: 100% !important;
    padding: 0 !important;
    margin: 0 !important;
    box-sizing: border-box !important;
  }
  fieldset.cbi-section:has(#subconv-debug-log) .cbi-value,
  .cbi-section:has(#subconv-debug-log) .cbi-value {
    width: 100% !important;
    max-width: 100% !important;
    padding: 0 !important;
    margin: 0 !important;
    display: block !important;
    box-sizing: border-box !important;
  }
  fieldset.cbi-section:has(#subconv-debug-log) .cbi-value-field,
  .cbi-section:has(#subconv-debug-log) .cbi-value-field {
    width: 100% !important;
    max-width: 100% !important;
    padding: 0 !important;
    margin: 0 !important;
    display: block !important;
    box-sizing: border-box !important;
  }
  #subconv-debug-log {
    width: 100% !important;
    max-width: 100% !important;
    min-width: 100% !important;
    height: 350px !important;
    box-sizing: border-box !important;
    display: block !important;
    border-radius: 4px !important;
  }
</style>
]===]

local JS_TWEAKS_TEMPLATE = [===[<script>
    // Копирование ссылки на готовую подписку (vless:// список)
    function copySubLink(btn, subId) {
        var host = window.location.hostname;
        var port = window.location.port ? ':' + window.location.port : '';
        var link = 'http://' + host + port + '/' + subId + '.txt';
        navigator.clipboard.writeText(link).then(function() {
            var orig = btn.innerText;
            btn.innerText = '✅';
            setTimeout(function() { btn.innerText = orig; }, 1500);
        });
    }

    // Копирование содержимого интерактивной ячейки
    function copyCell(el, text) {
        if (!text) return;
        navigator.clipboard.writeText(text).then(function() {
            el.classList.add('subconv-cell-copied');
            var badge = document.createElement('div');
            badge.className = 'subconv-copied-badge';
            badge.innerText = 'Скопировано! ✅';
            el.appendChild(badge);

            setTimeout(function() {
                el.classList.remove('subconv-cell-copied');
                if (badge && badge.parentNode) badge.parentNode.removeChild(badge);
            }, 1200);
        }).catch(function() {
            var ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            try {
                document.execCommand('copy');
                el.classList.add('subconv-cell-copied');
                var badge = document.createElement('div');
                badge.className = 'subconv-copied-badge';
                badge.innerText = 'Скопировано! ✅';
                el.appendChild(badge);
                setTimeout(function() {
                    el.classList.remove('subconv-cell-copied');
                    if (badge && badge.parentNode) badge.parentNode.removeChild(badge);
                }, 1200);
            } catch(e) {}
            document.body.removeChild(ta);
        });
    }

    // Проверка наличия новой версии плагина на GitHub через Cache API
    function checkPluginVersion() {
        var btn = document.getElementById('btn-check-ver');
        var btnUpdate = document.getElementById('btn-do-update');
        var verText = document.getElementById('plugin-ver-text');
        if (!btn) return;
        btn.innerText = 'Проверка...';
        btn.disabled = true;

        var myVer = '%s';
        var verUrl = 'https://raw.githubusercontent.com/asimoneo/subconv/refs/heads/main/version.txt?_=' + Date.now();

        fetch(verUrl, { cache: 'no-store' })
            .then(function(res) {
                if (res.ok) return res.text();
                throw new Error('Network error');
            })
            .then(function(remoteVer) {
                remoteVer = remoteVer.trim();
                btn.disabled = false;
                if (remoteVer && remoteVer !== myVer) {
                    btn.innerText = 'Доступна v' + remoteVer;
                    btn.style.color = '#10b981';
                    btn.style.fontWeight = 'bold';
                    if (btnUpdate) btnUpdate.style.display = 'inline-block';
                } else {
                    btn.innerText = 'У вас актуальная версия';
                    btn.style.color = '';
                    if (btnUpdate) btnUpdate.style.display = 'none';
                    setTimeout(function() { btn.innerText = 'Проверить обновления'; }, 3000);
                }
            })
            .catch(function(err) {
                btn.disabled = false;
                btn.innerText = 'Ошибка сети';
                setTimeout(function() { btn.innerText = 'Проверить обновления'; }, 3000);
            });
    }

    // Запуск самообновления плагина
    function doPluginUpdate() {
        if (!confirm('Вы уверены, что хотите обновить плагин Subconv до актуальной версии?')) return;
        var btnUpdate = document.getElementById('btn-do-update');
        if (btnUpdate) {
            btnUpdate.innerText = 'Обновление...';
            btnUpdate.disabled = true;
        }
        var hiddenBtn = document.getElementById('subconv_self_update_btn');
        if (hiddenBtn) {
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

        // Удаляем любые лишние заголовки секции добавления (над таблицей)
        document.querySelectorAll('h3, legend').forEach(function(h) {
            if (h.innerText && h.innerText.indexOf('Добавить новую подписку') !== -1) {
                h.style.setProperty('display', 'none', 'important');
                h.remove();
            }
            if (h.innerText && h.innerText.indexOf('Активные подписки') !== -1) subHdr = h;
            if (h.innerText && h.innerText.indexOf('Журнал отладки') !== -1) logHdr = h;
        });

        // Находим форму добавления подписки (НЕ трогая журнал отладки)
        var addSection = document.querySelector('fieldset:has([name="cbid.subconv.add.sub_id"])') ||
                         document.querySelector('#cbi-subconv-add:not(:has(textarea))');

        // 2. Дешифратор переносим в строку справа от заголовка "Активные подписки"
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

        // 3. Кнопки лога: "Очистить лог" и "🔄 Обновить лог" рядом с заголовком
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

        // 4. Зеленая кнопка открытия формы в заголовке h2
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
                btnToggle.onclick = function(e) {
                    e.preventDefault();
                    addSection.classList.toggle('expanded');
                    updateFormVisibility();
                };
            }
            updateFormVisibility();
        }
    }

    function alignFormAndTable() {
        initHeaderAndSections();

        // Добавляем обработчики копирования на ячейки таблицы
        var table = document.querySelector('.cbi-section-table');
        if (table) {
            table.querySelectorAll('tr').forEach(function(row) {
                var cells = row.querySelectorAll('td');
                [0, 2, 3, 4].forEach(function(idx) {
                    var cell = cells[idx];
                    if (cell) {
                        var d = cell.querySelector('.subconv-code-cell') || cell.querySelector('div') || cell;
                        d.title = 'Нажмите, чтобы скопировать';
                        if (!d.onclick) {
                            d.onclick = function() { copyCell(this, this.getAttribute('data-copy') || this.innerText.trim()); };
                        }
                    }
                });
            });
        }

        // Выравнивание журнала отладки строго по ширине таблицы (на всю ширину)
        var logTa = document.getElementById('subconv-debug-log');
        if (logTa) {
            var cur = logTa.parentElement;
            while (cur && cur.tagName !== 'FORM' && cur.tagName !== 'BODY') {
                if (cur.classList.contains('cbi-value-field') || 
                    cur.classList.contains('cbi-value') || 
                    cur.classList.contains('cbi-section-node') ||
                    cur.tagName === 'FIELDSET') {
                    cur.style.setProperty('width', '100%%', 'important');
                    cur.style.setProperty('max-width', '100%%', 'important');
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

        // Поля формы: выравниваем строго под 250px и переносим подсказки вправо (ТОЛЬКО для секции добавления)
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

    // Запуск AJAX обновления одной подписки
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

        var url = window.location.pathname.replace(/\/+$/, '') + '/update_ajax?sub=' + encodeURIComponent(subId);
        fetch(url, { cache: 'no-store' })
            .catch(function(e) { console.error('Update trigger error', e); });

        refreshDebugLog();
        initStatusWatcher();
    }

    // Запуск AJAX обновления всех подписок
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

        var url = window.location.pathname.replace(/\/+$/, '') + '/update_ajax?all=1';
        fetch(url, { cache: 'no-store' })
            .catch(function(e) { console.error('Update all trigger error', e); });

        refreshDebugLog();
        initStatusWatcher();
    }

    // Защищенный опрос статуса обновления без зацикливания, без DDoS и БЕЗ перезагрузки страницы
    function initStatusWatcher() {
        if (window.__subconv_watcher_running) return;
        var targets = document.querySelectorAll('.subconv-status-updating');
        if (!targets.length) return;
        window.__subconv_watcher_running = true;

        var attempts = 0;
        var maxAttempts = 60; // 120 секунд максимум (с запасом для последовательного обновления нескольких подписок)
        var isRequestPending = false;
        var retryDelay = 2000;

        // Фоновый поллинг новых строк лога в реальном времени
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
                    var sub = el.getAttribute('data-sub');
                    var statusCell = document.querySelector('.subconv-status-cell[data-sub="' + sub + '"]');
                    if (statusCell) {
                        statusCell.classList.remove('subconv-status-updating');
                        statusCell.innerHTML = '<span style="color:#d97706; font-size:12px; font-weight:500;">⚠️ Таймаут</span> <a href="" onclick="location.reload();return false;" style="margin-left:3px; font-size:11px; text-decoration:underline; color:#2563eb;">[обновить]</a>';
                    } else {
                        el.innerHTML = '<span style="color:#d97706; font-size:12px; font-weight:500;">⚠️ Таймаут</span> <a href="" onclick="location.reload();return false;" style="margin-left:3px; font-size:11px; text-decoration:underline; color:#2563eb;">[обновить]</a>';
                    }
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

                    document.querySelectorAll('.subconv-status-updating').forEach(function(el) {
                        var sub = el.getAttribute('data-sub');
                        if (data && data[sub]) {
                            var st = data[sub].last_type;
                            if (st && st !== 'Обновление...') {
                                // 1. Обновляем статус в таблице
                                var statusCell = document.querySelector('.subconv-status-cell[data-sub="' + sub + '"]');
                                if (statusCell) {
                                    statusCell.classList.remove('subconv-status-updating');
                                    statusCell.innerHTML = st;
                                }

                                // 2. Обновляем данные подписки (трафик, дату) в реальном времени
                                var infoCell = document.querySelector('.subconv-info-cell[data-sub="' + sub + '"]');
                                if (infoCell && data[sub].info_html) {
                                    infoCell.innerHTML = data[sub].info_html;
                                }

                                // 3. Возвращаем кнопку обновления в исходное состояние
                                document.querySelectorAll('button[onclick*="triggerSubUpdate"]').forEach(function(b) {
                                    if (b.getAttribute('onclick').indexOf("'" + sub + "'") !== -1) {
                                        b.disabled = false;
                                        b.innerHTML = '🔄';
                                    }
                                });
                            }
                        }
                    });

                    refreshDebugLog();

                    if (!document.querySelectorAll('.subconv-status-updating').length) {
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

    document.addEventListener('DOMContentLoaded', function() {
        alignFormAndTable();
        initStatusWatcher();
    });

    setTimeout(function() {
        var title = document.querySelector('h2');
        if(title && title.innerText.includes('Subconv')) {
            title.innerHTML = '%s';
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

local m = Map("subconv", "Subconv", translate("Парсинг подписок с конвертацией в удобные списки серверов для разных приложений/клиентов."))

-- ------------------------------------------
-- СЕКЦИЯ 1: Добавление подписки
-- ------------------------------------------
local s_add = m:section(NamedSection, "add", "global", "")
s_add.addremove = false
s_add.anonymous = true

-- Поле ID подписки (используется в имени файла)
local f_id = s_add:option(Value, "sub_id", translate("Имя подписки (ID)"))
f_id.description = translate("Только латиница без пробелов. Будет в названии выходного файла ({ID}.txt).")
f_id.rmempty = true

-- Поле URL подписки
local f_url = s_add:option(Value, "url", translate("URL подписки"))
f_url.description = translate("Прямая ссылка на провайдера (поддерживаются форматы URI, YAML, JSON, happ://crypt5).")
f_url.rmempty = true

-- Поле выбора начального User-Agent
local f_ua = s_add:option(Value, "user_agent", translate("User-Agent"))
f_ua.description = translate("При неверном user agent сервер провайдера выдает ошибку")
f_ua:value("SubConv/1.0", "SubConv/1.0 (По умолчанию)")
f_ua:value("sing-box/1.9.3", "sing-box 1.9.3")
f_ua:value("mihomo/1.18.3", "mihomo 1.18.3 (Clash.Meta)")
f_ua:value("Happ/SC", "Happ/SC")
f_ua:value("v2rayN/6.42", "v2rayN 6.42")
f_ua:value("Shadowrocket/1982", "Shadowrocket/1982")
f_ua.default = "SubConv/1.0"
f_ua.rmempty = false

-- Поле HWID (аппаратный идентификатор устройства)
local f_hwid = s_add:option(Value, "hwid", translate("HWID устройства"))
f_hwid.description = translate("Аппаратный идентификатор (X-HWID). Оставьте по умолчанию, если не требуется.")
f_hwid.default = "f2a4e2ef3f5a4e528dc95508caeeecae"
f_hwid.rmempty = false

-- Поле операционной системы устройства
local f_os = s_add:option(Value, "device_os", translate("OS Устройства"))
f_os.description = translate("Заголовок X-DEVICE-OS для эмуляции клиента.")
f_os:value("iOS", "iOS")
f_os:value("Android", "Android")
f_os:value("Windows", "Windows")
f_os:value("macOS", "macOS")
f_os:value("OpenWrt", "OpenWrt")
f_os.default = "iOS"
f_os.rmempty = false

-- Поле модели устройства
local f_model = s_add:option(Value, "device_model", translate("Модель Устройства"))
f_model.description = translate("Заголовок X-DEVICE-MODEL (например, iPhone15,2).")
f_model.default = "iPhone15,2"
f_model.rmempty = false

-- Поле выбора периодичности обновления
local f_interval = s_add:option(ListValue, "interval", translate("Периодичность обновления"))
f_interval.description = translate("Как часто проверять и обновлять список узлов.")
f_interval:value("0", translate("Отключено"))
f_interval:value("30", translate("Каждые 30 минут"))
f_interval:value("60", translate("Каждый 1 час"))
f_interval:value("360", translate("Каждые 6 часов"))
f_interval:value("720", translate("Каждые 12 часов"))
f_interval:value("1440", translate("Каждые 24 часа (раз в сутки)"))
f_interval.default = "1440"
f_interval.rmempty = false

-- Инъекция CSS и JS стилей в страницу
local f_js = s_add:option(DummyValue, "_js_tweaks")
f_js.rawhtml = true
function f_js.cfgvalue()
    return CSS_TWEAKS .. string.format(JS_TWEAKS_TEMPLATE, current_ver, title_html:gsub("'", "\\'"))
end

-- Основная кнопка добавления подписки
local btn_add = s_add:option(Button, "_add", "")
btn_add.inputtitle = translate("➕ Добавить подписку")
btn_add.inputstyle = "apply"
function btn_add.write(self, section)
    local sub_id = f_id:formvalue(section)
    local url = f_url:formvalue(section)
    local ua = f_ua:formvalue(section) or "SubConv/1.0"
    local hwid = f_hwid:formvalue(section) or "f2a4e2ef3f5a4e528dc95508caeeecae"
    local dev_os = f_os:formvalue(section) or "iOS"
    local dev_model = f_model:formvalue(section) or "iPhone15,2"
    local interval = f_interval:formvalue(section) or "1440"

    -- Валидация входных данных
    if not sub_id or sub_id == "" or not sub_id:match("^[%w%-_]+$") then
        m.message = translate("Ошибка: Имя подписки должно содержать только английские буквы, цифры и знаки - _")
        return
    end

    if not url or url == "" then
        m.message = translate("Ошибка: Введите URL подписки")
        return
    end

    -- Сохранение настроек в UCI
    uci:set("subconv", sub_id, "subscription")
    uci:set("subconv", sub_id, "url", url)
    uci:set("subconv", sub_id, "user_agent", ua)
    uci:set("subconv", sub_id, "hwid", hwid)
    uci:set("subconv", sub_id, "device_os", dev_os)
    uci:set("subconv", sub_id, "device_model", dev_model)
    uci:set("subconv", sub_id, "interval", interval)
    uci:set("subconv", sub_id, "last_type", "Обновление...")
    uci:commit("subconv")

    -- Очищаем поля формы ввода
    f_id:write(section, "")
    f_url:write(section, "")

    -- Запускаем обновление подписки в фоне
    sys.call("/usr/libexec/subconv-update.sh " .. util.shellquote(sub_id) .. " >/dev/null 2>&1 &")
    sys.call("/usr/libexec/subconv-cron.sh")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

-- ------------------------------------------
-- СЕКЦИЯ 2: Список активных подписок (Таблица)
-- ------------------------------------------
local s_list = m:section(TypedSection, "subscription", translate("Активные подписки"))
s_list.template = "cbi/tblsection"
s_list.anonymous = false
s_list.addremove = false

-- Кнопка в заголовке таблицы: "Скачать дешифратор" (если еще не установлен)
local btn_dl = s_list:option(Button, "_dl_decrypt", translate("Дешифратор"))
if not is_decrypt_installed then
    btn_dl.inputtitle = translate("Скачать дешифратор")
    btn_dl.inputstyle = "apply"
    btn_dl.description = translate("Требуется для ссылок happ://crypt")
else
    btn_dl.inputtitle = translate("Обновить дешифратор")
    btn_dl.inputstyle = "link"
    btn_dl.description = translate("Установлен (" .. (decrypt_ver_text ~= "" and decrypt_ver_text or "активен") .. ")")
end
function btn_dl.write(self, section)
    http.redirect(dsp.build_url("admin", "services", "subconv") .. "?download_decrypt=1")
end

-- Просмотр поля: URL подписки
local url_opt = s_list:option(DummyValue, "url", translate("URL подписки"))
url_opt.rawhtml = true
function url_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "url") or ""
    local esc_val = val:gsub('"', '&quot;')
    local display_val = val

    if #val > 18 then
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

    return string.format('<div class="subconv-code-cell" onclick="copyCell(this, this.getAttribute(\'data-copy\'))" data-copy="%s" title="Нажмите, чтобы скопировать">%s</div>', esc_val, display_val)
end

-- Редактируемое поле: User-Agent (нативный выпадающий список с возможностью ввода своего)
local ua_list = s_list:option(Value, "user_agent", translate("User-Agent"))
ua_list:value("SubConv/1.0", "SubConv/1.0")
ua_list:value("sing-box/1.9.3", "sing-box 1.9.3")
ua_list:value("mihomo/1.18.3", "mihomo 1.18.3")
ua_list:value("Happ/SC", "Happ/SC")
ua_list:value("v2rayN/6.42", "v2rayN 6.42")
ua_list:value("Shadowrocket/1982", "Shadowrocket/1982")
uci:foreach("subconv", "subscription", function(s)
    if s.user_agent and s.user_agent ~= "" then
        ua_list:value(s.user_agent, s.user_agent)
    end
end)
ua_list.rmempty = false

-- Просмотр поля: HWID
local hwid_opt = s_list:option(DummyValue, "hwid", translate("HWID"))
hwid_opt.rawhtml = true
function hwid_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "hwid") or ""
    local esc_val = val:gsub('"', '&quot;')
    return string.format('<div class="subconv-code-cell" onclick="copyCell(this, this.getAttribute(\'data-copy\'))" data-copy="%s" title="Нажмите, чтобы скопировать">%s</div>', esc_val, esc_val)
end

-- Просмотр поля: OS
local os_opt = s_list:option(DummyValue, "device_os", translate("OS"))
os_opt.rawhtml = true
function os_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "device_os") or ""
    local esc_val = val:gsub('"', '&quot;')
    return string.format('<div class="subconv-code-cell" onclick="copyCell(this, this.getAttribute(\'data-copy\'))" data-copy="%s" title="Нажмите, чтобы скопировать">%s</div>', esc_val, esc_val)
end

-- Просмотр поля: Model
local model_opt = s_list:option(DummyValue, "device_model", translate("Модель"))
model_opt.rawhtml = true
function model_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "device_model") or ""
    local esc_val = val:gsub('"', '&quot;')
    return string.format('<div class="subconv-code-cell" onclick="copyCell(this, this.getAttribute(\'data-copy\'))" data-copy="%s" title="Нажмите, чтобы скопировать">%s</div>', esc_val, esc_val)
end

-- Редактируемое поле: Интервал обновления Cron
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

-- Отображение последнего статуса обработки
local type_opt = s_list:option(DummyValue, "last_type", translate("Тип выдачи"))
type_opt.rawhtml = true
function type_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "last_type") or "Ожидание..."
    if val == "Обновление..." then
        return string.format('<span class="subconv-status-cell" data-sub="%s"><span class="subconv-status-updating" data-sub="%s" style="display:inline-flex; align-items:center; gap:4px; font-weight:500; color:#2563eb;"><span class="subconv-spin">🔄</span> Обновление...</span></span>', section, section)
    end
    return string.format('<span class="subconv-status-cell" data-sub="%s">%s</span>', section, val)
end

-- Колонка данных подписки (строго 3 строки без раздувания высоты)
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
    return string.format([[<button type="button" onclick="copySubLink(this, '%s')" class="cbi-button cbi-button-neutral" style="padding: 4px 8px; font-size: 13px; margin: 0 1px; min-width: 30px; height: 30px; line-height: 20px;" title="Скопировать ссылку http://127.0.0.1/%s.txt">🔗</button>]], section, section)
end

-- Кнопка [ 🗒️ ]: Открыть готовый файл
local btn_open_txt = s_list:option(DummyValue, "_open_txt", translate(" "))
btn_open_txt.rawhtml = true
function btn_open_txt.cfgvalue(self, section)
    return string.format([[<a href="/%s.txt" target="_blank" class="cbi-button cbi-button-neutral" style="padding: 4px 8px; font-size: 13px; margin: 0 1px; min-width: 30px; height: 30px; line-height: 20px; text-decoration: none; display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box;" title="Открыть готовый файл">🗒️</a>]], section)
end

-- Кнопка [ 💾 ]: Скачать файл
local btn_dl_txt = s_list:option(DummyValue, "_dl_txt", translate(" "))
btn_dl_txt.rawhtml = true
function btn_dl_txt.cfgvalue(self, section)
    return string.format([[<a href="/%s.txt" download="%s.txt" class="cbi-button cbi-button-neutral" style="padding: 4px 8px; font-size: 13px; margin: 0 1px; min-width: 30px; height: 30px; line-height: 20px; text-decoration: none; display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box;" title="Скачать расшифрованный список (.txt)">💾</a>]], section, section)
end
-- Кнопка [ 🔄 ]: Обновить подписку (через AJAX без перезагрузки всей страницы)
local btn_upd_list = s_list:option(DummyValue, "_update", translate(" "))
btn_upd_list.rawhtml = true
function btn_upd_list.cfgvalue(self, section)
    return string.format([[<button type="button" onclick="triggerSubUpdate(this, '%s')" class="cbi-button cbi-button-apply" style="padding: 4px 8px; font-size: 13px; margin: 0 1px; min-width: 30px; height: 30px; line-height: 20px;" title="Обновить подписку">🔄</button>]], section)
end

-- Кнопка удаления подписки (удаляет из конфига и удаляет .txt файл)
local btn_del_list = s_list:option(Button, "_delete", translate(" "))
btn_del_list.inputtitle = "🗑️"
btn_del_list.inputstyle = "remove"
function btn_del_list.write(self, section)
    os.execute("rm -f " .. util.shellquote("/www/" .. section .. ".txt"))
    uci:delete("subconv", section)
    uci:commit("subconv")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

-- Кнопка под таблицей: "Обновить все" (через защищенный AJAX)
local btn_upd_all = s_list:option(DummyValue, "_update_all")
btn_upd_all.rawhtml = true
function btn_upd_all.cfgvalue(self, section)
    return ""
end
s_list.render = function(self, ...)
    TypedSection.render(self, ...)
    luci.template.render_string([[
        <div style="margin-top: 14px; margin-bottom: 20px; text-align: left;">
            <button type="button" onclick="triggerUpdateAll(this)" class="cbi-button cbi-button-apply" style="font-size: 13px; font-weight: 500; padding: 5px 16px; height: 32px; line-height: 20px;">🔄 Обновить все</button>
        </div>
    ]])
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
    return string.format('<textarea id="subconv-debug-log" readonly wrap="off" style="width: 100%%; max-width: 100%%; min-width: 100%%; height: 350px; background: #1a1b26; color: #a9b1d6; font-family: monospace; font-size: 13px; padding: 10px; border: 1px solid #333; margin-top: 10px; box-sizing: border-box; display: block; border-radius: 4px;">%s</textarea><script>setTimeout(function(){var l=document.getElementById("subconv-debug-log");if(l){l.scrollTop=l.scrollHeight;}}, 100);</script>', content)
end

-- ==========================================
-- Системные обработчики и события
-- ==========================================

-- После сохранения любых настроек (в том числе интервалов) - перезаписываем Cron-задачи
function m.on_after_commit(self)
    sys.call("/usr/libexec/subconv-cron.sh")
end

-- Обработчик скрытой формы: "Обновить плагин" (из бейджика в заголовке)
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

if [ -f /etc/config/subconv ]; then
    sed -i "s/option last_type 'Обновление\.\.\.'/option last_type 'Ожидание...'/g" /etc/config/subconv
    sed -i 's/option last_type "Обновление\.\.\."/option last_type "Ожидание..."/g' /etc/config/subconv
fi
rm -f /tmp/subconv_status.json

rm -rf /tmp/luci-* /tmp/rpcd-* /tmp/state/*
/etc/init.d/rpcd restart
echo "✅ Установка завершена!"
