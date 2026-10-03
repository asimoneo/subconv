#!/bin/sh

echo "========================================================="
echo "        Установка Subconv (Умный парсер + Логи)          "
echo "========================================================="
echo "Выберите действие:"
echo " 1) Установить / Обновить плагин"
echo " 2) Полностью УДАЛИТЬ плагин и все его файлы"
echo "========================================================="
printf "Ваш выбор [1]: "
read action

if [ "$action" = "2" ]; then
    echo "Удаление Subconv..."
    
    if [ -f /etc/config/subconv ]; then
        for sub in $(grep -E "config subscription" /etc/config/subconv | awk -F"'" '{print $2}'); do
            if [ -n "$sub" ]; then
                echo "Удаление файла: /www/${sub}.txt"
                rm -f "/www/${sub}.txt"
            fi
        done
    fi

    rm -f /usr/libexec/subconv-update.sh
    rm -f /usr/libexec/subconv-cron.sh
    rm -f /usr/lib/lua/luci/controller/subconv.lua
    rm -f /usr/lib/lua/luci/model/cbi/subconv.lua
    rm -f /usr/share/luci/menu.d/subconv.json
    rm -f /usr/share/rpcd/acl.d/subconv.json
    rm -f /etc/config/subconv
    rm -f /www/subconv_debug.txt
    
    if [ -f /etc/crontabs/root ]; then
        sed -i '/subconv-update.sh/d' /etc/crontabs/root
        /etc/init.d/cron restart
    fi
    
    rm -rf /tmp/luci-* /tmp/rpcd-* /tmp/state/*
    /etc/init.d/rpcd restart
    
    echo "✅ Плагин, конфигурации и все скачанные подписки полностью удалены!"
    exit 0
fi

echo "0. Проверка и установка зависимостей..."
if ! command -v curl >/dev/null 2>&1; then
    echo "Установка curl (требуется для скачивания подписок)..."
    opkg update
    opkg install curl
fi

echo "1. Создание системных директорий..."
mkdir -p /usr/libexec
mkdir -p /usr/lib/lua/luci/model/cbi
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/share/luci/menu.d
mkdir -p /usr/share/rpcd/acl.d

echo "2. Создание безопасного скрипта обновления..."
cat << 'EOF' > /usr/libexec/subconv-update.sh
#!/usr/bin/lua
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local nixio = require "nixio"

local sub_id = arg[1]
local debug_file = "/www/subconv_debug.txt"
local f_dbg = io.open(debug_file, "a")

local function log(msg)
    if f_dbg then
        f_dbg:write(os.date("%Y-%m-%d %H:%M:%S") .. " [" .. (sub_id or "NONE") .. "] " .. msg .. "\n")
        f_dbg:flush()
    end
end

local function save_status(msg)
    local u = require "luci.model.uci".cursor()
    u:set("subconv", sub_id, "last_type", msg)
    u:commit("subconv")
end

log("=== СТАРТ ОБНОВЛЕНИЯ ===")
if not sub_id then
    log("Ошибка: не указан ID подписки")
    if f_dbg then f_dbg:close() end
    os.exit(1)
end

uci:load("subconv")
local url = uci:get("subconv", sub_id, "url")
local ua = uci:get("subconv", sub_id, "user_agent") or "SubConv/1.0"
local hwid = uci:get("subconv", sub_id, "hwid") or "openwrt-router-default"
local dev_os = uci:get("subconv", sub_id, "device_os") or "OpenWrt"
local dev_model = uci:get("subconv", sub_id, "device_model") or "OpenWrt Router"

if not url or url == "" then
    log("Ошибка: URL не задан")
    save_status("Ошибка: нет URL")
    if f_dbg then f_dbg:close() end
    os.exit(1)
end

local out_path = "/www/" .. sub_id .. ".txt"

log("Запрос по URL: " .. url)
log("Используем User-Agent: " .. ua)

local cmd = string.format("curl -k -L -s --connect-timeout 10 --max-time 30 -A %s -H %s -H %s -H %s %s",
    util.shellquote(ua),
    util.shellquote("X-HWID: " .. hwid),
    util.shellquote("X-DEVICE-OS: " .. dev_os),
    util.shellquote("X-DEVICE-MODEL: " .. dev_model),
    util.shellquote(url)
)

local handle = io.popen(cmd)
local resp = handle:read("*all")
handle:close()

if not resp or #resp == 0 then
    log("Ошибка: пустой ответ сервера или превышен таймаут")
    save_status("Ошибка загрузки (таймаут)")
else
    log("Получено данных: " .. #resp .. " байт")
    local decoded = resp
    local is_b64 = false
    local maybe_decoded = nixio.bin.b64decode(resp)
    
    if maybe_decoded and maybe_decoded:match("://") then
        decoded = maybe_decoded
        is_b64 = true
        log("Base64 успешно декодирован")
    end

    -- Умный детектор формата (RAW Конфиг или список URI)
    local is_raw = false
    local first_char = decoded:match("^%s*(.)")
    if first_char == "{" or first_char == "[" then
        is_raw = true
        log("Детектор: Обнаружен JSON формат")
    elseif decoded:match("\nproxies:") or decoded:match("^proxies:") then
        is_raw = true
        log("Детектор: Обнаружен YAML формат")
    end

    if is_raw then
        local f_out = io.open(out_path, "w")
        if f_out then
            f_out:write(decoded)
            f_out:close()
            log("УСПЕХ: Файл сохранен как готовый конфиг (JSON/YAML)")
            save_status("JSON/YAML Конфиг")
        else
            log("Ошибка записи в файл " .. out_path)
            save_status("Ошибка сохранения файла")
        end
    else
        local links = {}
        for line in decoded:gmatch("[^\r\n]+") do
            if line:match("://") then
                table.insert(links, line)
            end
        end

        if #links > 0 then
            local f_out = io.open(out_path, "w")
            if f_out then
                f_out:write(table.concat(links, "\n") .. "\n")
                f_out:close()
                log("УСПЕХ: Найдено узлов URI - " .. #links .. ". Сохранено в " .. out_path)
                
                if is_b64 then
                    save_status("Base64 URI (" .. #links .. ")")
                else
                    save_status("Текст URI (" .. #links .. ")")
                end
            else
                log("Ошибка записи в файл " .. out_path)
                save_status("Ошибка сохранения файла")
            end
        else
            log("ОШИБКА: Не найдено узлов URI и это не JSON/YAML")
            save_status("Пусто (Нет узлов)")
        end
    end
end

if f_dbg then f_dbg:close() end
EOF
chmod +x /usr/libexec/subconv-update.sh

echo "3. Создание скрипта Cron..."
cat << 'EOF' > /usr/libexec/subconv-cron.sh
#!/bin/sh
. /lib/functions.sh
touch /etc/crontabs/root
sed -i '/subconv-update.sh/d' /etc/crontabs/root

add_cron() {
    local cfg="$1"
    local enabled interval
    config_get_bool enabled "$cfg" enabled 0
    config_get interval "$cfg" interval 1440
    
    if [ "$enabled" -eq 1 ] && [ "$interval" -gt 0 ]; then
        local cron_expr=""
        case "$interval" in
            30) cron_expr="*/30 * * * *" ;;
            60) cron_expr="0 * * * *" ;;
            360) cron_expr="0 */6 * * *" ;;
            720) cron_expr="0 */12 * * *" ;;
            1440) cron_expr="0 4 * * *" ;;
        esac
        
        if [ -n "$cron_expr" ]; then
            echo "$cron_expr /usr/libexec/subconv-update.sh $cfg >/dev/null 2>&1" >> /etc/crontabs/root
        fi
    fi
}
config_load subconv
config_foreach add_cron subscription
/etc/init.d/cron restart
EOF
chmod +x /usr/libexec/subconv-cron.sh

echo "4. Создание меню для LuCI..."
cat << 'EOF' > /usr/share/luci/menu.d/subconv.json
{
    "admin/services/subconv": {
        "title": "Subconv",
        "order": 90,
        "action": {
            "type": "cbi",
            "path": "subconv"
        },
        "depends": {
            "acl": [ "luci-app-subconv" ]
        }
    }
}
EOF

echo "5. Создание файла прав доступа..."
cat << 'EOF' > /usr/share/rpcd/acl.d/subconv.json
{
    "luci-app-subconv": {
        "description": "Grant access to Subconv",
        "read": {
            "uci": [ "subconv" ]
        },
        "write": {
            "uci": [ "subconv" ]
        }
    }
}
EOF

echo "6. Создание контроллера LuCI..."
cat << 'EOF' > /usr/lib/lua/luci/controller/subconv.lua
module("luci.controller.subconv", package.seeall)
function index()
    entry({"admin", "services", "subconv"}, cbi("subconv"), _("Subconv"), 90).dependent = true
end
EOF

echo "7. Создание интерфейса LuCI..."
cat << 'EOF' > /usr/lib/lua/luci/model/cbi/subconv.lua
local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local http = require "luci.http"
local dsp = require "luci.dispatcher"
local util = require "luci.util"

local m = Map("subconv", translate("Subconv"), translate("Парсинг подписок и конвертация в списки для HomeProxy."))

local sys_os = "OpenWrt"
local f_rel = io.open("/etc/openwrt_release", "r")
if f_rel then
    local content = f_rel:read("*all")
    f_rel:close()
    for line in content:gmatch("[^\r\n]+") do
        if line:match("^DISTRIB_ID=") then sys_os = line:match("DISTRIB_ID=['\"]?(.-)['\"]?$") end
        if line:match("^DISTRIB_RELEASE=") then
            local rel = line:match("DISTRIB_RELEASE=['\"]?(.-)['\"]?$")
            if rel then sys_os = sys_os .. " " .. rel end
        end
    end
end

local sys_model = "OpenWrt Router"
local f_mod = io.open("/tmp/sysinfo/model", "r")
if f_mod then
    local m_val = f_mod:read("*all")
    f_mod:close()
    if m_val and m_val ~= "" then sys_model = m_val:gsub("^%s+", ""):gsub("%s+$", "") end
end

local sys_hwid = "openwrt-router-default"
local f_hwid_file = io.open("/etc/machine-id", "r")
if f_hwid_file then
    local hw = f_hwid_file:read("*all"):gsub("^%s+", ""):gsub("%s+$", "")
    if hw ~= "" then sys_hwid = hw end
    f_hwid_file:close()
end

sys_os = sys_os:gsub("[\r\n]", "")
sys_model = sys_model:gsub("[\r\n]", "")
sys_hwid = sys_hwid:gsub("[\r\n]", "")

local s_add = m:section(NamedSection, "add", "global", translate("Добавить новую подписку"))
s_add.addremove = false
s_add.anonymous = true

local f_id = s_add:option(Value, "sub_id", translate("Имя подписки (ID)"))
f_id.description = translate("Только латиница. Имя файла будет совпадать ({ID}.txt).")
f_id.rmempty = true

local f_url = s_add:option(Value, "url", translate("URL подписки"))
f_url.rmempty = true

local f_ua = s_add:option(Value, "user_agent", translate("User-Agent"))
f_ua.description = translate("Влияет на формат выдачи (выберите из списка или введите свой)")
f_ua:value("SubConv/1.0", "SubConv/1.0 (По умолчанию)")
f_ua:value("sing-box/1.9.3", "sing-box 1.9.3")
f_ua:value("mihomo/1.18.3", "mihomo 1.18.3 (Clash.Meta)")
f_ua:value("Happ/SC", "Happ/SC")
f_ua:value("v2rayN/6.42", "v2rayN 6.42")
f_ua:value("Shadowrocket/1982", "Shadowrocket/1982")
f_ua.default = "SubConv/1.0"
f_ua.rmempty = true

local f_hwid_opt = s_add:option(Value, "hwid", translate("HWID устройства"))
f_hwid_opt:value(sys_hwid, sys_hwid .. " (Ваш роутер)")
f_hwid_opt:value("windows-pc-hwid-01", "Windows PC")
f_hwid_opt:value("macbook-pro-hwid-02", "MacBook Pro")
f_hwid_opt:value("iphone-15-hwid-03", "iPhone 15")
f_hwid_opt:value("android-phone-hwid-04", "Android Phone")
f_hwid_opt.default = sys_hwid
f_hwid_opt.rmempty = true

local f_os = s_add:option(Value, "device_os", translate("OS Устройства"))
f_os:value(sys_os, sys_os .. " (Ваша ОС)")
f_os:value("Windows 11", "Windows 11")
f_os:value("Windows 10", "Windows 10")
f_os:value("macOS 14.0", "macOS 14.0")
f_os:value("iOS 17.0", "iOS 17.0")
f_os:value("Android 14", "Android 14")
f_os:value("Linux", "Linux")
f_os.default = sys_os
f_os.rmempty = true

local f_model = s_add:option(Value, "device_model", translate("Модель Устройства"))
f_model:value(sys_model, sys_model .. " (Ваша модель)")
f_model:value("PC", "PC")
f_model:value("MacBook Pro M2", "MacBook Pro M2")
f_model:value("iPhone 15 Pro", "iPhone 15 Pro")
f_model:value("Samsung Galaxy S24", "Samsung Galaxy S24")
f_model:value("Xiaomi 14", "Xiaomi 14")
f_model.default = sys_model
f_model.rmempty = true

local f_interval = s_add:option(ListValue, "interval", translate("Интервал обновления"))
f_interval:value("0", translate("Отключено"))
f_interval:value("30", translate("Каждые 30 мин"))
f_interval:value("60", translate("Каждый 1 час"))
f_interval:value("360", translate("Каждые 6 часов"))
f_interval:value("720", translate("Каждые 12 часов"))
f_interval:value("1440", translate("Раз в сутки"))
f_interval.default = "1440"

local btn_add = s_add:option(Button, "_add", translate("Добавить подписку"))
btn_add.inputstyle = "add"
function btn_add.write(self, section)
    local new_id = m:formvalue("cbid.subconv.add.sub_id")
    local new_url = m:formvalue("cbid.subconv.add.url")
    local new_ua = m:formvalue("cbid.subconv.add.user_agent") or "SubConv/1.0"
    local new_interval = m:formvalue("cbid.subconv.add.interval") or "1440"
    local new_hwid_val = m:formvalue("cbid.subconv.add.hwid") or sys_hwid
    local new_os = m:formvalue("cbid.subconv.add.device_os") or sys_os
    local new_model = m:formvalue("cbid.subconv.add.device_model") or sys_model

    if new_id and new_id ~= "" and new_url and new_url ~= "" then
        new_id = string.gsub(new_id, "[^%w_]", "_")

        uci:section("subconv", "subscription", new_id, {
            enabled = "1",
            url = new_url,
            user_agent = new_ua,
            hwid = new_hwid_val,
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
end

local s_list = m:section(TypedSection, "subscription", translate("Активные подписки"))
s_list.anonymous = true
s_list.addremove = false
s_list.template = "cbi/tblsection"

local en = s_list:option(Flag, "enabled", translate("Вкл"))
en.rmempty = false
en.default = "1"
en.enabled = "1"
en.disabled = "0"

s_list:option(Value, "url", translate("URL")).rmempty = false

local ua_list = s_list:option(Value, "user_agent", translate("User-Agent"))
ua_list:value("SubConv/1.0", "SubConv/1.0")
ua_list:value("sing-box/1.9.3", "sing-box 1.9.3")
ua_list:value("mihomo/1.18.3", "mihomo 1.18.3")
ua_list:value("Happ/SC", "Happ/SC")
ua_list:value("v2rayN/6.42", "v2rayN 6.42")
ua_list:value("Shadowrocket/1982", "Shadowrocket/1982")
ua_list.rmempty = false

s_list:option(DummyValue, "hwid", translate("HWID"))
s_list:option(DummyValue, "device_os", translate("OS"))
s_list:option(DummyValue, "device_model", translate("Модель"))

local interval_list = s_list:option(ListValue, "interval", translate("Обновление"))
interval_list:value("0", translate("Откл"))
interval_list:value("30", translate("30 мин"))
interval_list:value("60", translate("1 час"))
interval_list:value("360", translate("6 часов"))
interval_list:value("720", translate("12 часов"))
interval_list:value("1440", translate("24 часа"))
interval_list.rmempty = false

local type_opt = s_list:option(DummyValue, "last_type", translate("Тип выдачи"))
type_opt.rawhtml = true
function type_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "last_type") or "Ожидание..."
    if val == "Ожидание..." or val == "Обновление..." then
        return val .. ' <script>setTimeout(function(){location.reload();}, 3000);</script>'
    end
    return val
end

local link_opt = s_list:option(DummyValue, "_link", translate("Локальная ссылка"))
link_opt.rawhtml = true
function link_opt.cfgvalue(self, section)
    local display_url = "http://127.0.0.1/" .. section .. ".txt"
    local href_url = "/" .. section .. ".txt"
    return string.format('<a href="%s" target="_blank" title="Кликните для просмотра файла">%s</a>', href_url, display_url)
end

local btn_upd_list = s_list:option(Button, "_update", translate("Обновить"))
btn_upd_list.inputstyle = "apply"
function btn_upd_list.write(self, section)
    uci:set("subconv", section, "last_type", "Обновление...")
    uci:commit("subconv")
    sys.call("/usr/libexec/subconv-update.sh " .. util.shellquote(section) .. " >/dev/null 2>&1 &")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

local btn_del_list = s_list:option(Button, "_delete", translate("Удалить"))
btn_del_list.inputstyle = "remove"
function btn_del_list.write(self, section)
    os.execute("rm -f " .. util.shellquote("/www/" .. section .. ".txt"))
    uci:delete("subconv", section)
    uci:commit("subconv")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

-- Секция с журналом отладки внизу
local s_log = m:section(TypedSection, "global", translate("Журнал отладки"))
s_log.anonymous = true
s_log.addremove = false
function s_log.filter(self, section)
    return section == "add"
end

local btn_clear = s_log:option(Button, "_clear_log", translate("Очистить лог"))
btn_clear.inputstyle = "remove"
function btn_clear.write(self, section)
    os.execute("rm -f /www/subconv_debug.txt")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

local log_view = s_log:option(DummyValue, "_logview")
log_view.rawhtml = true
function log_view.cfgvalue(self, section)
    local f = io.open("/www/subconv_debug.txt", "r")
    local content = f and f:read("*all") or "Лог пуст. Нажмите «Обновить» на любой подписке для проверки."
    if f then f:close() end
    content = content:gsub("<", "&lt;"):gsub(">", "&gt;")
    
    return string.format(
        '<textarea readonly wrap="off" style="width: 100%%; height: 350px; background: #1a1b26; color: #a9b1d6; font-family: monospace; font-size: 13px; padding: 10px; resize: vertical; border: 1px solid #333; margin-top: 10px;">%s</textarea>' ..
        '<script>setTimeout(function(){var t=document.getElementsByTagName("textarea");var l=t[t.length-1];if(l){l.scrollTop=l.scrollHeight;}}, 100);</script>', 
        content
    )
end

function m.on_after_commit(self)
    sys.call("/usr/libexec/subconv-cron.sh")
end

return m
EOF

echo "8. Создание конфигурационного файла UCI..."
if [ ! -f /etc/config/subconv ]; then
    cat << 'EOF' > /etc/config/subconv
config global 'add'
EOF
else
    if ! grep -q "config global 'add'" /etc/config/subconv; then
        echo "config global 'add'" >> /etc/config/subconv
    fi
fi

echo "9. Очистка кэша LuCI..."
rm -rf /tmp/luci-* /tmp/rpcd-* /tmp/state/*
/etc/init.d/rpcd restart

echo "=========================================="
echo "✅ Установка успешно завершена!"
echo "=========================================="
