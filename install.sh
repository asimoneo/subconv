#!/bin/sh

VERSION="0.3.14"
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
    log("Обнаружена крипто-ссылка. Запуск локальной дешифровки (Бинарник)...")
    local bin_path = "/usr/libexec/happ-decrypt"
    
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
local function fetch_subscription(url, ua, hwid, dev_os, dev_model)
    local cmd = string.format("curl -k -L -s -w '%%{http_code}' --connect-timeout 10 --max-time 30 -A %s -H %s -H %s -H %s %s",
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

-- Безопасная запись данных в локальный файл
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
if url:match("^happ://crypt") or url:match("^v2raytun://crypt") then
    url = decrypt_happ_url(url)
end

log("Запрос: " .. sub_id)
log("Заголовки: UA=" .. ua .. " | HWID=" .. hwid .. " | OS=" .. dev_os)

-- 3. Выполняем запрос к серверу провайдера
local resp_raw = fetch_subscription(url, ua, hwid, dev_os, dev_model)
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

cat << EOF > /usr/lib/lua/luci/model/cbi/subconv.lua
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
local HTML_DECRYPT_OK = "<span style='color:#4caf50; font-weight:bold;'>✅ Установлен</span> (Нажмите для обновления)"
local HTML_DECRYPT_WARN = "<span style='color:#ff9800; font-weight:bold;'>⚠ Не установлен</span> (Нажмите для загрузки)"
local HTML_VER_OK = '<span style="color:#4caf50; font-size:12px; margin-left:10px;">✅ актуальная</span>'
local HTML_VER_OUTDATED = '<span style="color:#ff9800; font-size:12px; margin-left:10px;">⚠ старая версия, актуальная - %s</span> <button type="submit" name="subconv_self_update" value="1" class="cbi-button cbi-button-apply" style="margin-left:5px; padding:2px 8px; font-size:11px;">Обновить</button>'

-- JS-твики для кастомизации интерфейса LuCI: 
-- Выравнивает поля в секции добавления подписки и добавляет бейджики версии в заголовок
local JS_TWEAKS_TEMPLATE = [[
<script>
    setTimeout(function() {
        // Улучшаем отображение полей ввода
        document.querySelectorAll('#cbi-subconv-add .cbi-value').forEach(function(el) {
            var field = el.querySelector('.cbi-value-field');
            var desc = el.querySelector('.cbi-value-description');
            if (field && desc) {
                field.style.display = 'flex';
                field.style.alignItems = 'center';
                field.style.gap = '15px';
                field.appendChild(desc);
                desc.style.margin = '0';
                desc.style.opacity = '0.8';
                desc.style.fontSize = '12px';
            }
        });
        
        // Внедряем версию в заголовок страницы
        var title = document.querySelector('h2');
        if(title && title.innerText.includes('Subconv')) {
            title.innerHTML = '%s';
        }
    }, 100);
</script>
]]

-- ==========================================
-- Основная CBI Модель
-- ==========================================
local m = Map("subconv", "Subconv", translate("Парсинг подписок и конвертация в списки для HomeProxy."))

-- ------------------------------------------
-- СЕКЦИЯ 1: Добавление новой подписки
-- ------------------------------------------
local s_add = m:section(NamedSection, "add", "global", translate("Добавить новую подписку"))
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
f_ua.description = translate("Маскировка клиента. Некоторые серверы отдают узлы только под определенные UA.")
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
    -- Меняем описание кнопки в зависимости от того, есть ли бинарник в системе
    self.description = nixio.fs.access("/usr/libexec/happ-decrypt") and HTML_DECRYPT_OK or HTML_DECRYPT_WARN
end
function f_decrypt.write(self, section)
    -- Скрипт скачивания актуального бинарника дешифратора с GitHub
    local script = [[
        COMMIT_SHA=$(curl -sSL --connect-timeout 5 https://api.github.com/repos/asimoneo/subconv/commits/main | grep '"sha"' | head -n 1 | awk -F '"' '{print $4}')
        if [ -n "$COMMIT_SHA" ]; then
            curl -fsSL "https://raw.githubusercontent.com/asimoneo/subconv/${COMMIT_SHA}/happ-decrypt" -o /usr/libexec/happ-decrypt
        else
            curl -fsSL "https://raw.githubusercontent.com/asimoneo/subconv/refs/heads/main/happ-decrypt" -o /usr/libexec/happ-decrypt
        fi
        chmod +x /usr/libexec/happ-decrypt
    ]]
    local f = io.open("/tmp/dl_decrypt.sh", "w")
    if f then
        f:write(script)
        f:close()
        sys.call("sh /tmp/dl_decrypt.sh")
        os.remove("/tmp/dl_decrypt.sh")
    end
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

-- ==========================================
-- Логика проверки обновлений (версия плагина)
-- ==========================================
local current_ver = "$VERSION"
local cache_file = "/tmp/subconv_ver_cache"
local remote_ver, commit_sha, ts = current_ver, "main", 0

-- Читаем кеш (чтобы не дергать GitHub API при каждом обновлении страницы)
local f = io.open(cache_file, "r")
if f then
    local content = f:read("*a")
    f:close()
    local pts, pver, psha = content:match("^(%d+)|(.-)|(.*)$")
    if pts then 
        ts = tonumber(pts)
        remote_ver = pver:gsub("%s+", "") 
        if psha and psha ~= "" then commit_sha = psha:gsub("%s+", "") end
    end
end

-- Если кеш устарел (более 10 сек), запрашиваем версию с GitHub
if os.time() - ts > 86400 then
    local h_sha = io.popen("curl -sL --connect-timeout 3 --max-time 5 https://api.github.com/repos/asimoneo/subconv/commits/main")
    if h_sha then
        local fetched_sha = h_sha:read("*a"):match('"sha"%s*:%s*"([^"]+)"')
        h_sha:close()
        if fetched_sha then
            commit_sha = fetched_sha
            local h = io.popen("curl -sL --connect-timeout 3 --max-time 5 https://raw.githubusercontent.com/asimoneo/subconv/" .. commit_sha .. "/install.sh | grep '^VERSION=' | head -n 1")
            if h then
                local fetched = h:read("*a"):match('VERSION="(.-)"')
                h:close()
                if fetched then
                    remote_ver = fetched:gsub("%s+", "")
                    local fw = io.open(cache_file, "w")
                    if fw then fw:write(os.time() .. "|" .. remote_ver .. "|" .. commit_sha); fw:close() end
                end
            end
        end
    end
end

-- Формируем HTML-код бейджика версии для инъекции
local update_html = (remote_ver == current_ver) and HTML_VER_OK or string.format(HTML_VER_OUTDATED, remote_ver)
local title_inj = string.format([[<a href="https://github.com/asimoneo/subconv" target="_blank" style="text-decoration:none; color:inherit; border-bottom: 1px dashed;">Subconv</a> <span style="font-size: 14px; opacity: 0.6; font-weight: normal; margin-left: 8px;">v%s</span> %s]], current_ver, update_html)

-- Скрытое поле, через которое мы внедряем JS-твики (описанные выше)
local f_js = s_add:option(DummyValue, "_js_tweaks")
f_js.rawhtml = true
function f_js.cfgvalue()
    return string.format(JS_TWEAKS_TEMPLATE, title_inj:gsub("'", "\'"))
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

-- Отображение URL (с маскировкой длинных ссылок для безопасности)
local url_list = s_list:option(DummyValue, "url", translate("URL"))
url_list.rawhtml = true
function url_list.cfgvalue(self, section)
    local val = uci:get("subconv", section, "url") or ""
    local esc_val = val:gsub('"', '&quot;')
    local hidden_val = string.sub(esc_val, 1, math.min(math.floor(#val / 2), 35)) .. "••••••••"
    -- Добавляем спойлер (ссылка показывается полностью при наведении мыши)
    return string.format('<div style="word-break: break-all; min-width: 200px; font-size: 11px; line-height: 1.2; cursor: pointer;" onmouseover="this.innerText=this.getAttribute(\'data-url\')" onmouseout="this.innerText=\'%s\'" data-url="%s">%s</div>', hidden_val, esc_val, hidden_val)
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
    return string.format('<div style="word-break: break-all; font-family: monospace; font-size: 11px; line-height: 1.2; min-width: 100px;">%s</div>', uci:get("subconv", section, "hwid") or "")
end

-- Просмотр поля: OS
local os_opt = s_list:option(DummyValue, "device_os", translate("OS"))
os_opt.rawhtml = true
function os_opt.cfgvalue(self, section)
    return string.format('<div style="font-size: 11px;">%s</div>', uci:get("subconv", section, "device_os") or "")
end

-- Просмотр поля: Model
local model_opt = s_list:option(DummyValue, "device_model", translate("Модель"))
model_opt.rawhtml = true
function model_opt.cfgvalue(self, section)
    return string.format('<div style="font-size: 11px;">%s</div>', uci:get("subconv", section, "device_model") or "")
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
    -- Если подписка в процессе обновления — автообновляем страницу через 3 сек
    if val == "Ожидание..." or val == "Обновление..." then
        return val .. ' <script>setTimeout(function(){location.reload();}, 3000);</script>'
    end
    return val
end

-- Вывод сгенерированной ссылки для копирования в HomeProxy
local link_opt = s_list:option(DummyValue, "_link", translate("Название (ID) и ссылка"))
link_opt.rawhtml = true
function link_opt.cfgvalue(self, section)
    return string.format('<div style="line-height: 1.4; white-space: nowrap;"><b>%s</b><br><a href="/%s.txt" target="_blank" title="Открыть файл">http://127.0.0.1/%s.txt</a></div>', section, section, section)
end

-- Кнопка ручного обновления конкретной подписки
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
local btn_clear = s_log:option(Button, "_clear_log", translate("Очистить лог"))
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
    local f = io.open(cache_file, "r")
    local sha = "main"
    if f then
        local c_sha = f:read("*a"):match("^(%d+)|(.-)|(.*)$")
        if c_sha and c_sha ~= "" then sha = c_sha:gsub("%s+", "") end
        f:close()
    end
    -- Скачиваем скрипт по указанному SHA и запускаем его в режиме "1" (обновление)
    sys.call("curl -sSL https://raw.githubusercontent.com/asimoneo/subconv/" .. sha .. "/install.sh | sh -s 1 >/dev/null 2>&1 &")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

return m
EOF

if [ ! -f /etc/config/subconv ]; then
    echo "config global 'add'" > /etc/config/subconv
elif ! grep -q "config global 'add'" /etc/config/subconv; then
    echo "config global 'add'" >> /etc/config/subconv
fi

rm -rf /tmp/luci-* /tmp/rpcd-* /tmp/state/*
/etc/init.d/rpcd restart
echo "✅ Установка завершена!"
