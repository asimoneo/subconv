#!/bin/sh

echo "=== Установка SubConv (asimoneo/subconv) ==="

echo "1. Создание системных директорий..."
mkdir -p /usr/libexec
mkdir -p /usr/lib/lua/luci/model/cbi
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/share/luci/menu.d
mkdir -p /usr/share/rpcd/acl.d

echo "2. Создание скрипта обновления (/usr/libexec/subconv-update.sh)..."
cat << 'EOF' > /usr/libexec/subconv-update.sh
#!/usr/bin/lua
local uci = require "luci.model.uci".cursor()

local sub_id = arg[1]
local debug_file = "/www/subconv_debug.txt"
local f_dbg = io.open(debug_file, "w")

local function log(msg)
    if f_dbg then
        f_dbg:write(msg .. "\n")
        f_dbg:flush()
    end
end

log("=== СТАРТ ОБНОВЛЕНИЯ (Lua) ===")

if not sub_id then
    log("Ошибка: не указан ID подписки")
    if f_dbg then f_dbg:close() end
    os.exit(1)
end

uci:load("subconv")
local url = uci:get("subconv", sub_id, "url")
local ua = uci:get("subconv", sub_id, "user_agent") or "mihomo"
local hwid = uci:get("subconv", sub_id, "hwid")
local dev_os = uci:get("subconv", sub_id, "device_os") or "OpenWrt"
local dev_model = uci:get("subconv", sub_id, "device_model") or "OpenWrt Router"

if not url or url == "" then
    log("Ошибка: URL не задан для " .. sub_id)
    if f_dbg then f_dbg:close() end
    os.exit(1)
end

if not hwid or hwid == "" then
    local f = io.open("/etc/machine-id", "r")
    if f then
        hwid = f:read("*all"):gsub("%s+", "")
        f:close()
    end
    if not hwid or hwid == "" then
        hwid = "openwrt-router-default"
    end
end

log("URL: " .. url)
log("HWID: " .. hwid)

local cmd = string.format("curl -k -L -s -A '%s' -H 'X-HWID: %s' -H 'X-DEVICE-OS: %s' -H 'X-DEVICE-MODEL: %s' '%s'",
    ua, hwid, dev_os, dev_model, url)

local handle = io.popen(cmd)
local resp = handle:read("*all")
handle:close()

log("Получено байт: " .. #resp)

if #resp == 0 then
    log("Ошибка: пустой ответ от сервера")
    if f_dbg then f_dbg:close() end
    os.exit(1)
end

local out_path = "/www/" .. sub_id .. ".txt"
local f_out = io.open(out_path, "w")
if f_out then
    f_out:write(resp)
    f_out:close()
    log("УСПЕХ: записано в " .. out_path)
    if f_dbg then f_dbg:close() end
    os.exit(0)
else
    log("Ошибка записи в файл " .. out_path)
    if f_dbg then f_dbg:close() end
    os.exit(1)
end
EOF
chmod +x /usr/libexec/subconv-update.sh

echo "3. Создание скрипта Cron (/usr/libexec/subconv-cron.sh)..."
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
        local m=$((interval % 60))
        local h=$((interval / 60))
        local cron_expr
        if [ "$h" -eq 0 ]; then
            cron_expr="*/$interval * * * *"
        elif [ "$h" -lt 24 ]; then
            cron_expr="$m */$h * * *"
        else
            local d=$((h / 24))
            cron_expr="$m 0 */$d * *"
        fi
        echo "$cron_expr /usr/libexec/subconv-update.sh $cfg >/dev/null 2>&1" >> /etc/crontabs/root
    fi
}
config_load subconv
config_foreach add_cron subscription
/etc/init.d/cron restart
EOF
chmod +x /usr/libexec/subconv-cron.sh

echo "4. Создание меню для новых версий OpenWrt (/usr/share/luci/menu.d/subconv.json)..."
cat << 'EOF' > /usr/share/luci/menu.d/subconv.json
{
    "admin/services/subconv": {
        "title": "Конвертер подписок (SubConv)",
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

echo "5. Создание файла прав доступа rpcd (/usr/share/rpcd/acl.d/subconv.json)..."
cat << 'EOF' > /usr/share/rpcd/acl.d/subconv.json
{
    "luci-app-subconv": {
        "description": "Grant access to SubConv",
        "read": {
            "uci": [ "subconv" ]
        },
        "write": {
            "uci": [ "subconv" ]
        }
    }
}
EOF

echo "6. Создание классического контроллера LuCI (/usr/lib/lua/luci/controller/subconv.lua)..."
cat << 'EOF' > /usr/lib/lua/luci/controller/subconv.lua
module("luci.controller.subconv", package.seeall)

function index()
    entry({"admin", "services", "subconv"}, cbi("subconv"), _("Конвертер подписок (SubConv)"), 90).dependent = true
end
EOF

echo "7. Создание интерфейса LuCI (/usr/lib/lua/luci/model/cbi/subconv.lua)..."
cat << 'EOF' > /usr/lib/lua/luci/model/cbi/subconv.lua
local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local http = require "luci.http"
local dsp = require "luci.dispatcher"

local m = Map("subconv", translate("Конвертер подписок (SubConv)"), 
    translate("Парсинг подписок и конвертация для HomeProxy."))

local s = m:section(TypedSection, "subscription", translate("Управление подписками"))
s.anonymous = false
s.addremove = true
s.template = "cbi/tblsection"

local enabled = s:option(Flag, "enabled", translate("Вкл"))
enabled.rmempty = false

local url = s:option(Value, "url", translate("URL подписки"))
url.rmempty = false

local ua = s:option(Value, "user_agent", translate("User-Agent"))
ua.default = "mihomo"

local hwid = s:option(Value, "hwid", translate("HWID"))

local interval = s:option(Value, "interval", translate("Интервал (мин)"))
interval.datatype = "uinteger"
interval.default = "1440"

local link = s:option(DummyValue, "_link", translate("Локальная ссылка"))
function link.cfgvalue(self, section)
    return "http://127.0.0.1/" .. section .. ".txt"
end

local btn_upd = s:option(Button, "_update", translate("Обновить"))
btn_upd.inputstyle = "apply"
function btn_upd.write(self, section)
    local r = sys.call("/usr/libexec/subconv-update.sh " .. section)
    if r == 0 then
        m.message = "✅ Подписка [" .. section .. "] успешно обновлена."
    else
        m.message = "❌ Ошибка при обновлении [" .. section .. "]. См. /www/subconv_debug.txt"
    end
end

function s.create(self, section)
    local created = TypedSection.create(self, section)
    if created then
        uci:set("subconv", created, "enabled", "1")
        uci:set("subconv", created, "user_agent", "mihomo")
        uci:set("subconv", created, "interval", "1440")
        uci:commit("subconv")
    end
    return created
end

function m.on_after_commit(self)
    sys.call("/usr/libexec/subconv-cron.sh")
end

return m
EOF

echo "8. Создание конфигурационного файла UCI (/etc/config/subconv)..."
if [ ! -f /etc/config/subconv ]; then
    touch /etc/config/subconv
fi

echo "9. Очистка кэша LuCI..."
rm -rf /tmp/luci-* /tmp/rpcd-* /tmp/state/*
/etc/init.d/rpcd restart

echo "=========================================="
echo "✅ Установка успешно завершена!"
echo "Перейдите в веб-интерфейс LuCI -> Службы -> Конвертер подписок (SubConv)"
echo "=========================================="
