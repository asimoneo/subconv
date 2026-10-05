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

-- Проверка наличия ID подписки
if not sub_id then
    log("Ошибка: ID подписки не указан при вызове скрипта.")
    os.exit(1)
end

-- Чтение параметров подписки из /etc/config/subconv
local url = uci:get("subconv", sub_id, "url")
local ua = uci:get("subconv", sub_id, "user_agent") or "SubConv/1.0"
local hwid = uci:get("subconv", sub_id, "hwid")
local dev_os = uci:get("subconv", sub_id, "device_os")
local dev_model = uci:get("subconv", sub_id, "device_model")

log("Начало обновления подписки. User-Agent: " .. ua)

if not url or url == "" then
    save_status("Ошибка: Пустой URL")
    log("Ошибка: URL пустой в конфигурации.")
    os.exit(1)
end

-- ==========================================
-- Обработка протоколов happ://crypt
-- ==========================================
-- Если ссылка начинается с happ://, нам нужно скачать зашифрованные данные
-- и передать их внешнему бинарнику happ-decrypt (Go) для расшифровки AES/RC4.
if url:match("^happ://") then
    log("Обнаружена happ:// ссылка. Подготовка к расшифровке...")
    
    -- Превращаем happ://crypt5/xxx в https://crypt5/xxx для скачивания по HTTP/HTTPS
    local http_url = url:gsub("^happ://", "https://")
    local raw_file = "/tmp/happ_raw_" .. sub_id .. ".bin"
    local dec_file = "/tmp/happ_dec_" .. sub_id .. ".txt"

    -- Формируем команду curl со всеми необходимыми заголовками устройства
    local headers = string.format("-H %s", util.shellquote("User-Agent: " .. ua))
    if hwid and hwid ~= "" then
        headers = headers .. string.format(" -H %s", util.shellquote("device-hwid: " .. hwid))
    end
    if dev_os and dev_os ~= "" then
        headers = headers .. string.format(" -H %s", util.shellquote("device-os: " .. dev_os))
    end
    if dev_model and dev_model ~= "" then
        headers = headers .. string.format(" -H %s", util.shellquote("device-model: " .. dev_model))
    end

    local cmd = string.format("curl -s -L -k --connect-timeout 15 -m 30 %s %s -o %s -D /tmp/happ_hdr_%s.txt",
        headers, util.shellquote(http_url), util.shellquote(raw_file), sub_id)
    
    log("Выполнение запроса: " .. cmd)
    local ret = sys.call(cmd)

    -- Читаем Userinfo из заголовков HTTP-ответа (трафик, дата окончания)
    local h_file = io.open("/tmp/happ_hdr_" .. sub_id .. ".txt", "r")
    if h_file then
        local h_data = h_file:read("*all")
        h_file:close()
        os.remove("/tmp/happ_hdr_" .. sub_id .. ".txt")
        
        local userinfo = h_data:match("subscription%-userinfo:%s*([^\r\n]+)")
        if not userinfo then
            userinfo = h_data:match("Subscription%-Userinfo:%s*([^\r\n]+)")
        end
        if userinfo then
            local u = tonumber(userinfo:match("upload=(%d+)")) or 0
            local d = tonumber(userinfo:match("download=(%d+)")) or 0
            local total = tonumber(userinfo:match("total=(%d+)")) or 0
            local expire = tonumber(userinfo:match("expire=(%d+)")) or 0
            
            local u_cursor = require "luci.model.uci".cursor()
            u_cursor:set("subconv", sub_id, "userinfo", string.format("%d|%d|%d", (u + d), total, expire))
            u_cursor:commit("subconv")
            log(string.format("Сохранен Userinfo: использовано %d, всего %d, истекает %d", (u + d), total, expire))
        end
    end

    if ret ~= 0 then
        save_status("Ошибка: сбой скачивания")
        log("Ошибка скачивания happ:// файла, код возврата curl: " .. tostring(ret))
        os.exit(1)
    end

    -- Вызов Go-дешифратора happ-decrypt
    local dec_bin = "/usr/libexec/happ-decrypt"
    if nixio.fs.access(dec_bin) then
        local dec_cmd = string.format("%s -u %s -i %s -o %s", 
            util.shellquote(dec_bin), util.shellquote(url), util.shellquote(raw_file), util.shellquote(dec_file))
        log("Вызов Go-дешифратора: " .. dec_cmd)
        local d_ret = sys.call(dec_cmd)
        os.remove(raw_file)
        
        if d_ret ~= 0 or not nixio.fs.access(dec_file) then
            save_status("Ошибка: сбой дешифратора")
            log("Дешифратор вернул ошибку: " .. tostring(d_ret))
            os.exit(1)
        end
    else
        save_status("Ошибка: нет дешифратора")
        log("Дешифратор не найден в /usr/libexec/happ-decrypt!")
        os.remove(raw_file)
        os.exit(1)
    end

    -- Читаем расшифрованные данные
    local f_dec = io.open(dec_file, "r")
    if not f_dec then
        save_status("Ошибка чтения расшифровки")
        log("Не удалось открыть файл расшифровки: " .. dec_file)
        os.exit(1)
    end
    local content = f_dec:read("*all")
    f_dec:close()
    os.remove(dec_file)

    -- Если результат валиден, сохраняем его в /www/{ID}.txt
    if content and #content > 0 then
        local out_f = io.open("/www/" .. sub_id .. ".txt", "w")
        if out_f then
            out_f:write(content)
            out_f:close()
            save_status("happ-decrypt (OK)")
            log("Успешно сохранено " .. #content .. " байт в /www/" .. sub_id .. ".txt")
            os.exit(0)
        else
            save_status("Ошибка записи /www")
            log("Ошибка открытия на запись файла /www/" .. sub_id .. ".txt")
            os.exit(1)
        end
    else
        save_status("Ошибка: Пустой вывод")
        log("Ошибка: Дешифратор выдал 0 байт.")
        os.exit(1)
    end
end

-- ==========================================
-- Обработка обычных ссылок (HTTP/HTTPS)
-- ==========================================
-- Скачиваем содержимое по прямой ссылке
local raw_file = "/tmp/raw_" .. sub_id .. ".txt"
local headers = string.format("-H %s", util.shellquote("User-Agent: " .. ua))
if hwid and hwid ~= "" then headers = headers .. string.format(" -H %s", util.shellquote("device-hwid: " .. hwid)) end
if dev_os and dev_os ~= "" then headers = headers .. string.format(" -H %s", util.shellquote("device-os: " .. dev_os)) end
if dev_model and dev_model ~= "" then headers = headers .. string.format(" -H %s", util.shellquote("device-model: " .. dev_model)) end

local cmd = string.format("curl -s -L -k --connect-timeout 15 -m 30 %s %s -o %s -D /tmp/hdr_%s.txt",
    headers, util.shellquote(url), util.shellquote(raw_file), sub_id)

log("Выполнение curl: " .. cmd)
local ret = sys.call(cmd)

-- Считываем Userinfo из заголовков HTTP-ответа
local h_file = io.open("/tmp/hdr_" .. sub_id .. ".txt", "r")
if h_file then
    local h_data = h_file:read("*all")
    h_file:close()
    os.remove("/tmp/hdr_" .. sub_id .. ".txt")
    
    local userinfo = h_data:match("subscription%-userinfo:%s*([^\r\n]+)")
    if not userinfo then
        userinfo = h_data:match("Subscription%-Userinfo:%s*([^\r\n]+)")
    end
    if userinfo then
        local u = tonumber(userinfo:match("upload=(%d+)")) or 0
        local d = tonumber(userinfo:match("download=(%d+)")) or 0
        local total = tonumber(userinfo:match("total=(%d+)")) or 0
        local expire = tonumber(userinfo:match("expire=(%d+)")) or 0
        
        local u_cursor = require "luci.model.uci".cursor()
        u_cursor:set("subconv", sub_id, "userinfo", string.format("%d|%d|%d", (u + d), total, expire))
        u_cursor:commit("subconv")
        log(string.format("Сохранен Userinfo: использовано %d, всего %d, истекает %d", (u + d), total, expire))
    end
end

if ret ~= 0 then
    save_status("Ошибка: сбой скачивания")
    log("Ошибка скачивания по curl, код ошибки: " .. tostring(ret))
    os.exit(1)
end

local f_raw = io.open(raw_file, "r")
if not f_raw then
    save_status("Ошибка: нет файла")
    log("Не удалось прочитать скачанный файл: " .. raw_file)
    os.exit(1)
end
local content = f_raw:read("*all")
f_raw:close()
os.remove(raw_file)

if not content or #content == 0 then
    save_status("Ошибка: пустой ответ")
    log("Сервер вернул пустой ответ (0 байт).")
    os.exit(1)
end

-- ==========================================
-- Анализ типа контента (Base64, JSON, YAML, URI)
-- ==========================================
local detected_type = "Неизвестный"
local clean_content = content:gsub("^%s+", ""):gsub("%s+$", "")

-- 1. Проверка на Base64
local b64_test = nixio.bin.b64decode(clean_content)
if b64_test and (b64_test:match("vless://") or b64_test:match("vmess://") or b64_test:match("ss://") or b64_test:match("trojan://")) then
    detected_type = "Base64 (URI)"
    content = b64_test
-- 2. Проверка на JSON
elseif clean_content:sub(1,1) == "{" or clean_content:sub(1,1) == "[" then
    detected_type = "JSON"
-- 3. Проверка на YAML / Clash Config
elseif clean_content:match("proxies:") or clean_content:match("port:") then
    detected_type = "YAML (Clash)"
-- 4. Обычные прямые ссылки (URI)
elseif clean_content:match("vless://") or clean_content:match("vmess://") or clean_content:match("ss://") or clean_content:match("trojan://") then
    detected_type = "Plain (URI)"
end

-- Сохраняем итоговый результат
local out_f = io.open("/www/" .. sub_id .. ".txt", "w")
if out_f then
    out_f:write(content)
    out_f:close()
    save_status(detected_type .. " (OK)")
    log("Успешно сохранено " .. #content .. " байт (" .. detected_type .. ") в /www/" .. sub_id .. ".txt")
    os.exit(0)
else
    save_status("Ошибка записи /www")
    log("Ошибка открытия файла /www/" .. sub_id .. ".txt на запись")
    os.exit(1)
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
  }
  @keyframes subconvBadgeFloat {
    0% { opacity: 0; transform: translate(-50%, 4px) scale(0.85); }
    15% { opacity: 1; transform: translate(-50%, 0) scale(1); }
    75% { opacity: 1; transform: translate(-50%, -2px) scale(1); }
    100% { opacity: 0; transform: translate(-50%, -10px) scale(0.9); }
  }

  /* Кол 2 (User-Agent): ширина 120px, видимые стрелки и всплывающее меню поверх таблицы */
  .cbi-section-table th:nth-child(2),
  .cbi-section-table td:nth-child(2) {
    width: 120px !important;
    overflow: visible !important;
  }
  .cbi-section-table td:nth-child(2) cbi-dropdown,
  .cbi-section-table td:nth-child(2) .cbi-dropdown,
  .cbi-section-table td:nth-child(2) select {
    width: 120px !important;
    max-width: 120px !important;
    font-size: 11px !important;
    box-sizing: border-box !important;
  }
  .cbi-section-table td:nth-child(2) cbi-dropdown[open],
  .cbi-section-table td:nth-child(2) .cbi-dropdown[open] {
    position: relative !important;
    z-index: 9999 !important;
  }
  .cbi-section-table td:nth-child(2) cbi-dropdown > ul:not(.preview),
  .cbi-section-table td:nth-child(2) .cbi-dropdown > ul:not(.preview) {
    position: absolute !important;
    z-index: 10000 !important;
    min-width: 140px !important;
    max-width: 220px !important;
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.5) !important;
    white-space: normal !important;
  }

  /* Кол 3 (HWID): перенос в 2 строки без полосы прокрутки */
  .cbi-section-table td:nth-child(3) {
    min-width: 0 !important;
    white-space: normal !important;
    line-height: 1.25 !important;
    font-size: 11px !important;
  }

  /* Кол 4 (OS): перенос при необходимости в 2 строки */
  .cbi-section-table td:nth-child(4) {
    min-width: 0 !important;
    white-space: normal !important;
    line-height: 1.25 !important;
    font-size: 11px !important;
  }

  /* Кол 5 (Модель): перенос при необходимости в 2 строки */
  .cbi-section-table td:nth-child(5) {
    min-width: 0 !important;
    white-space: normal !important;
    line-height: 1.25 !important;
    font-size: 11px !important;
  }

  /* Кол 6 (Обновление) и Кол 7 (Тип выдачи) */
  .cbi-section-table td:nth-child(6) select,
  .cbi-section-table td:nth-child(6) cbi-dropdown,
  .cbi-section-table td:nth-child(6) .cbi-dropdown {
    font-size: 11px !important;
  }
  .cbi-section-table td:nth-child(7) {
    white-space: normal !important;
    line-height: 1.25 !important;
    font-size: 11px !important;
  }

  /* Кол 8: Данные подписки (строго 3 строки: название, лимит/срок, остаток) */
  .cbi-section-table th:nth-child(8),
  .cbi-section-table td:nth-child(8) {
    white-space: nowrap !important;
    min-width: 180px !important;
  }

  /* 6. Кнопки действий справа: ПОЛНЫЙ РАЗМЕР */
  .cbi-section-table th:nth-last-child(-n+5),
  .cbi-section-table td:nth-last-child(-n+5) {
    width: 36px !important;
    max-width: 40px !important;
    padding: 4px 2px !important;
    text-align: center !important;
    white-space: nowrap !important;
  }
  .cbi-section-table td:nth-last-child(-n+5) .cbi-button,
  .cbi-section-table td:nth-last-child(-n+5) a.cbi-button {
    margin: 0 1px !important;
    padding: 4px 8px !important;
    font-size: 13px !important;
    min-width: 30px !important;
    height: 30px !important;
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
    box-shadow: 0 4px 14px rgba(16, 185, 129, 0.4) !important;
    transform: translateY(-1px) !important;
  }
</style>]===]

local JS_TWEAKS_TEMPLATE = [===[<script>
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
                    var current = '%s';
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

        // 3. Кнопку "Очистить лог" переносим справа от заголовка "Журнал отладки", скрывая саму строку
        var btnClear = document.querySelector('[name*="_clear_log"]');
        if (logHdr && btnClear) {
            var clearRow = btnClear.closest('.cbi-value') || document.querySelector('div[id*="_clear_log"]');
            if (clearRow && clearRow !== btnClear) clearRow.style.setProperty('display', 'none', 'important');
            if (btnClear.parentNode !== logHdr) {
                logHdr.style.display = 'flex';
                logHdr.style.alignItems = 'center';
                logHdr.style.gap = '15px';
                btnClear.style.cssText = 'margin: 0; font-size: 12px; padding: 3px 10px; height: 26px; line-height: 18px; cursor: pointer; vertical-align: middle;';
                logHdr.appendChild(btnClear);
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
                btnToggle.onclick = function() {
                    addSection.classList.toggle('expanded');
                    updateFormVisibility();
                };
            }

            if (addSection.querySelector('.cbi-value-error')) {
                addSection.classList.add('expanded');
            }

            updateFormVisibility();
        }
    }

    function alignFormAndTable() {
        initHeaderAndSections();

        // Убираем текст (процесс может занять некоторое время), если остался
        document.querySelectorAll('.cbi-section-descr, span').forEach(function(s) {
            if (s.innerText && s.innerText.indexOf('процесс может занять некоторое время') !== -1) {
                s.remove();
            }
        });

        // Навешиваем обработчики на кликабельные поля (URL, HWID, OS, Модель)
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

    setTimeout(function() {
        var title = document.querySelector('h2');
        if(title && title.innerText.includes('Subconv')) {
            title.innerHTML = '%s';
        }
        alignFormAndTable();
    }, 50);

    setTimeout(alignFormAndTable, 200);
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

-- Поле ID подписки (используется как имя файла)
local f_id = s_add:option(Value, "sub_id", translate("Имя подписки (ID)"))
f_id.description = translate("Только латиница без пробелов. Задает имя выходного файла ({ID}.txt).")
f_id.rmempty = true

-- Поле URL подписки
local f_url = s_add:option(Value, "url", translate("URL подписки"))
f_url.description = translate("Прямая ссылка от провайдера (поддерживаются форматы URI, YAML, JSON, happ://crypt5).")
f_url.rmempty = true

-- Поле выбора поддельного User-Agent
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

-- Поле выбора идентификатора HWID (очень важно для провайдера Geodema)
local f_hwid_opt = s_add:option(Value, "hwid", translate("HWID устройства"))
f_hwid_opt.description = translate("Уникальный идентификатор устройства. Защищает от блокировки за мультиаккаунт.")
f_hwid_opt:value(random_hwid, random_hwid .. " (Случайный - По умолчанию)")
f_hwid_opt:value(sys_hwid, sys_hwid .. " (Ваш роутер)")
f_hwid_opt.default = random_hwid
f_hwid_opt.rmempty = true

-- Поле выбора фейковой ОС
local f_os = s_add:option(Value, "device_os", translate("OS Устройства"))
f_os.description = translate("Операционная система, которая будет указана в заголовках запроса.")
f_os:value(sys_os, sys_os)
f_os:value("Windows 11", "Windows 11")
f_os:value("iOS 17.0", "iOS 17.0")
f_os:value("Android 14", "Android 14")
f_os.default = sys_os
f_os.rmempty = true

-- Поле выбора фейковой модели устройства
local f_model = s_add:option(Value, "device_model", translate("Модель Устройства"))
f_model.description = translate("Название устройства для передачи провайдеру.")
f_model:value(sys_model, sys_model)
f_model:value("PC", "PC")
f_model:value("iPhone 15 Pro", "iPhone 15 Pro")
f_model:value("Android Phone", "Android Phone")
f_model.default = sys_model
f_model.rmempty = true

-- Выбор интервала автоматического обновления (создает правило в Cron)
local f_interval = s_add:option(ListValue, "interval", translate("Интервал обновления"))
f_interval.description = translate("Как часто роутер будет автоматически скачивать свежие узлы (через Cron).")
f_interval:value("0", translate("Отключено"))
f_interval:value("30", translate("Каждые 30 мин"))
f_interval:value("60", translate("Каждый 1 час"))
f_interval:value("360", translate("Каждые 6 часов"))
f_interval:value("720", translate("Каждые 12 часов"))
f_interval:value("1440", translate("Раз в сутки"))
f_interval.default = "1440"

-- Кнопка установки/обновления Go-дешифратора
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

-- Скрытое поле, через которое мы внедряем JS-твики (описанные выше)
local f_js = s_add:option(DummyValue, "_js_tweaks")
f_js.rawhtml = true
function f_js.cfgvalue()
    return CSS_TWEAKS .. string.format(JS_TWEAKS_TEMPLATE, current_ver, title_html:gsub("'", "\\'"))
end

-- Основная кнопка добавления подписки
local btn_add = s_add:option(Button, "_add", "")
btn_add.inputtitle = translate("➕ Добавить подписку")
btn_add.inputstyle = "add"
function btn_add.write(self, section)
    local new_id = m:formvalue("cbid.subconv.add.sub_id")
    local new_url = m:formvalue("cbid.subconv.add.url")
    
    if new_id and new_id ~= "" and new_url and new_url ~= "" then
        -- Очистка имени от пробелов и спецсимволов
        new_id = string.gsub(new_id, "[^%w_]", "_")
        
        -- Защита от перезаписи существующих подписок
        if uci:get("subconv", new_id) then
            m.message = "Ошибка: Подписка с именем '" .. new_id .. "' уже существует!"
            return
        end

        -- Сохранение настроек новой подписки в /etc/config/subconv
        uci:section("subconv", "subscription", new_id, {
            url = new_url,
            user_agent = m:formvalue("cbid.subconv.add.user_agent") or "SubConv/1.0",
            hwid = m:formvalue("cbid.subconv.add.hwid") or random_hwid,
            device_os = m:formvalue("cbid.subconv.add.device_os") or sys_os,
            device_model = m:formvalue("cbid.subconv.add.device_model") or sys_model,
            interval = m:formvalue("cbid.subconv.add.interval") or "1440",
            last_type = "Ожидание..."
        })
        -- Очистка полей ввода в форме
        uci:set("subconv", "add", "sub_id", "")
        uci:set("subconv", "add", "url", "")
        uci:commit("subconv")
        
        -- Асинхронный запуск скрипта обновления (в фоне)
        sys.call("/usr/libexec/subconv-update.sh " .. util.shellquote(new_id) .. " >/dev/null 2>&1 &")
        http.redirect(dsp.build_url("admin", "services", "subconv"))
    end
end

-- ------------------------------------------
-- СЕКЦИЯ 2: Таблица активных подписок
-- ------------------------------------------
local list_title = translate("Активные подписки") .. [[ <button type="submit" name="update_all" value="1" class="cbi-button cbi-button-apply" style="margin-left: 15px; font-size: 12px; padding: 4px 12px;">🔄 Обновить все</button> <span style="font-weight: normal; font-size: 12px; opacity: 0.7; margin-left: 10px;">(процесс может занять некоторое время)</span>]]
local s_list = m:section(TypedSection, "subscription", list_title)
s_list.anonymous = true
s_list.addremove = false
s_list.template = "cbi/tblsection"

-- Отображение URL (стандарт токенов GitHub / AWS с лимитом длины до 2 строк)
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

    return string.format('<div class="subconv-code-cell" onclick="copyCell(this, this.getAttribute(\'data-copy\'))" data-copy="%s" title="Нажмите, чтобы скопировать">%s</div>', esc_val, display_val)
end

-- Редактируемое поле: User-Agent
local ua_list = s_list:option(Value, "user_agent", translate("User-Agent"))
ua_list.size = "12"
ua_list:value("SubConv/1.0", "SubConv/1.0")
ua_list:value("sing-box/1.9.3", "sing-box 1.9.3")
ua_list:value("mihomo/1.18.3", "mihomo 1.18.3")
ua_list:value("Happ/SC", "Happ/SC")
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

-- Отображение последнего статуса обработки
local type_opt = s_list:option(DummyValue, "last_type", translate("Тип выдачи"))
type_opt.rawhtml = true
function type_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "last_type") or "Ожидание..."
    if val == "Ожидание..." or val == "Обновление..." then
        return val .. ' <script>setTimeout(function(){location.reload();}, 3000);</script>'
    end
    return val
end

-- Колонка данных подписки (строго 3 строки без раздувания высоты)
local link_opt = s_list:option(DummyValue, "_link", translate("Данные подписки"))
link_opt.rawhtml = true
function link_opt.cfgvalue(self, section)
    local uinfo = uci:get("subconv", section, "userinfo")
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
    return string.format([[<div style="line-height: 1.3; white-space: nowrap;"><div style="font-size: 13px; font-weight: bold;">%s</div>%s%s</div>]], section, l2, l3)
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
local btn_upd_list = s_list:option(Button, "_update", translate(" "))
btn_upd_list.inputtitle = "🔄"
btn_upd_list.inputstyle = "apply"
function btn_upd_list.write(self, section)
    uci:set("subconv", section, "last_type", "Обновление...")
    uci:commit("subconv")
    sys.call("/usr/libexec/subconv-update.sh " .. util.shellquote(section) .. " >/dev/null 2>&1 &")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
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
    -- Вывод логов в терминал-подобный блок с автоматической прокруткой вниз
    return string.format('<textarea readonly wrap="off" style="width: 100%%; height: 350px; background: #1a1b26; color: #a9b1d6; font-family: monospace; font-size: 13px; padding: 10px; border: 1px solid #333; margin-top: 10px;">%s</textarea><script>setTimeout(function(){var t=document.getElementsByTagName("textarea");var l=t[t.length-1];if(l){l.scrollTop=l.scrollHeight;}}, 100);</script>', content)
end

-- ==========================================
-- Системные обработчики и события
-- ==========================================

-- После сохранения любых настроек (в том числе интервалов) - перезаписываем Cron-задачи
function m.on_after_commit(self)
    sys.call("/usr/libexec/subconv-cron.sh")
end

-- Обработчик скрытой формы: "Обновить все"
if http.formvalue("update_all") == "1" then
    uci:foreach("subconv", "subscription", function(s)
        if s.interval ~= "0" then
            uci:set("subconv", s['.name'], "last_type", "Обновление...")
            sys.call("/usr/libexec/subconv-update.sh " .. util.shellquote(s['.name']) .. " >/dev/null 2>&1 &")
        end
    end)
    uci:commit("subconv")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
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

rm -rf /tmp/luci-* /tmp/rpcd-* /tmp/state/*
/etc/init.d/rpcd restart
echo "✅ Установка завершена!"
