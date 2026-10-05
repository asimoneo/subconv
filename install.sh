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
    u:commit("subconv")
end

-- Централизованный обработчик ошибок (пишет в лог, обновляет статус и завершает работу)
local function exit_with_error(msg, status_msg)
    log("ОШИБКА: " .. msg)
    if status_msg then save_status(status_msg) end
    os.exit(1)
end

-- Функция маскировки URL для безопасности логов (скрывает вторую половину токенов)
local function mask_url(u)
    if not u then return "" end
    local v_len = math.min(math.floor(#u / 2), 35)
    return u:sub(1, v_len) .. "••••••••"
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
    log("Обнаружена крипто-ссылка. Дешифратор: " .. bin_ver .. "...")

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

log("Запрос: " .. sub_id)
log("Заголовки: UA=" .. ua .. " | HWID=" .. hwid .. " | OS=" .. dev_os)

-- 3. Выполняем запрос к серверу провайдера
local hdr_file = "/tmp/sub_headers_" .. (sub_id or "tmp") .. ".tmp"
local resp_raw = fetch_subscription(url, ua, hwid, dev_os, dev_model, hdr_file)
local uinfo_str = parse_userinfo(hdr_file)
if uinfo_str and sub_id then
    uci:set("subconv", sub_id, "userinfo", uinfo_str)
    uci:commit("subconv")
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
. /lib/functions.sh
touch /etc/crontabs/root
sed -i '/subconv-update.sh/d' /etc/crontabs/root

add_cron() {
    local cfg="$1"
    local interval
    config_get interval "$cfg" interval 1440
    
    if [ "$interval" -gt 0 ]; then
        local cron_expr=""
        case "$interval" in
            30) cron_expr="*/30 * * * *" ;;
            60) cron_expr="0 * * * *" ;;
            360) cron_expr="0 */6 * * *" ;;
            720) cron_expr="0 */12 * * *" ;;
            1440) cron_expr="0 4 * * *" ;;
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

-- ==========================================
-- Вспомогательные функции для получения системной информации
-- (Необходимы для передачи правильных заголовков Geodema)
-- ==========================================
local function get_sys_info()
    -- Парсим версию ОС из /etc/openwrt_release
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

    -- Читаем аппаратную модель роутера
    local model = "OpenWrt Router"
    local f_mod = io.open("/tmp/sysinfo/model", "r")
    if f_mod then
        local m_val = f_mod:read("*all")
        f_mod:close()
        if m_val and m_val ~= "" then model = m_val:gsub("^%s+", ""):gsub("%s+$", "") end
    end

    -- Получаем системный Machine ID (уникален для устройства, сохраняется при перезагрузках)
    local hwid = "openwrt-router-default"
    local f_hwid = io.open("/etc/machine-id", "r")
    if f_hwid then
        local hw = f_hwid:read("*all"):gsub("^%s+", ""):gsub("%s+$", "")
        if hw ~= "" then hwid = hw end
        f_hwid:close()
    end

    -- Генерируем случайный HWID на случай, если системный недоступен или не подходит
    local rnd_hwid = sys.exec("cat /proc/sys/kernel/random/uuid 2>/dev/null"):gsub("-", ""):gsub("%s+", ""):sub(1, 16)
    if not rnd_hwid or rnd_hwid == "" then rnd_hwid = "happ" .. tostring(os.time()) end

    return os_ver:gsub("[\r\n]", ""), model:gsub("[\r\n]", ""), hwid:gsub("[\r\n]", ""), rnd_hwid:gsub("[\r\n]", "")
end

-- Инициализация системных переменных
local sys_os, sys_model, sys_hwid, random_hwid = get_sys_info()

-- ==========================================
-- Константы для HTML и JavaScript
-- (Вынесены отдельно, чтобы не засорять логику Lua)
-- ==========================================
local current_ver = "0.3.16"

local title_html = string.format([[<a href="https://github.com/asimoneo/subconv" target="_blank" style="text-decoration:none; color:inherit; border-bottom: 1px dashed;">Subconv</a> <span style="font-size: 14px; opacity: 0.6; font-weight: normal; margin-left: 8px;" id="plugin-ver-text">v%s</span> <button type="button" class="cbi-button" style="margin-left: 10px; font-size: 12px; padding: 2px 6px;" id="btn-check-ver" onclick="checkPluginVersion()">Проверить обновления</button><button type="button" class="cbi-button cbi-button-apply" style="margin-left: 5px; font-size: 12px; padding: 2px 6px; display: none;" id="btn-do-update" onclick="doPluginUpdate()">Обновить</button>]], current_ver)

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

  /* 5. ТАБЛИЦА: аккуратные отступы 5px (зазор 10px) и строгая гармония */
  .cbi-section-table {
    table-layout: auto !important;
    border-collapse: collapse !important;
  }
  .cbi-section-table th,
  .cbi-section-table td {
    padding: 6px 5px !important;
    vertical-align: middle !important;
    text-align: left !important;
    box-sizing: border-box !important;
  }
  .cbi-section-table th {
    white-space: nowrap !important;
  }

  /* Интерактивные кликабельные поля (URL, HWID, OS, Модель): обводка и фон только при :hover */
  .subconv-code-cell {
    display: inline-block !important;
    position: relative !important;
    max-width: 100% !important;
    padding: 2px 6px !important;
    border-radius: 4px !important;
    border: 1px solid transparent !important;
    background: transparent !important;
    font-family: SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace !important;
    font-size: 11px !important;
    line-height: 1.25 !important;
    word-break: break-all !important;
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

  /* Усиленная анимация двоения (ghosting / chromatic duplication) при копировании */
  @keyframes subconvCellGhost {
    0% {
      transform: scale(1);
      box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7);
    }
    20% {
      transform: scale(1.04);
      text-shadow: -4px 0 3px rgba(59, 130, 246, 0.95), 4px 0 3px rgba(16, 185, 129, 0.95);
      box-shadow: -3px 0 0 1px rgba(59, 130, 246, 0.6), 3px 0 0 1px rgba(16, 185, 129, 0.6);
    }
    45% {
      transform: scale(1.03);
      text-shadow: -5px 0 5px rgba(59, 130, 246, 0.8), 5px 0 5px rgba(16, 185, 129, 0.8);
      box-shadow: 0 0 14px rgba(16, 185, 129, 0.65);
    }
    70% {
      transform: scale(1.01);
      text-shadow: -2px 0 2px rgba(59, 130, 246, 0.5), 2px 0 2px rgba(16, 185, 129, 0.5);
    }
    100% {
      transform: scale(1);
      text-shadow: none;
      box-shadow: none;
    }
  }
  .subconv-cell-copied {
    animation: subconvCellGhost 0.6s ease-out !important;
  }

  /* Всплывающий бейдж "Скопировано! ✅" прямо над ячейкой */
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
