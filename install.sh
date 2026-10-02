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

local sys_os = "OpenWrt"
local f_rel = io.open("/etc/openwrt_release", "r")
if f_rel then
    local content = f_rel:read("*all")
    f_rel:close()
    for line in content:gmatch("[^\r\n]+") do
        if line:match("^DISTRIB_ID=") then
            sys_os = line:match("DISTRIB_ID=['\"]?(.-)['\"]?$")
        end
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
    if m_val and m_val ~= "" then
        sys_model = m_val:gsub("^%s+", ""):gsub("%s+$", "")
    end
end

local sys_hwid = ""
local f_hwid = io.open("/etc/machine-id", "r")
if f_hwid then
    sys_hwid = f_hwid:read("*all"):gsub("^%s+", ""):gsub("%s+$", "")
    f_hwid:close()
end
if sys_hwid == "" then
    sys_hwid = sys.exec("uci get network.lan.mac 2>/dev/null | tr -d ':'"):gsub("^%s+", ""):gsub("%s+$", "")
end
if sys_hwid == "" then
    sys_hwid = "openwrt-router-default"
end

local new_id = http.formvalue("cbid.subconv.new.sub_id")
local new_url = http.formvalue("cbid.subconv.new.url")
local new_ua = http.formvalue("cbid.subconv.new.user_agent")
local new_hwid = http.formvalue("cbid.subconv.new.hwid")
local new_dev_os = http.formvalue("cbid.subconv.new.device_os")
local new_dev_model = http.formvalue("cbid.subconv.new.device_model")
local do_add = http.formvalue("cbid.subconv.new._add")

if do_add and new_id and new_id ~= "" and new_url and new_url ~= "" then
    new_id = string.gsub(new_id, "[^%w_]", "_")
    
    if not new_ua or new_ua == "" then new_ua = "mihomo" end
    if not new_hwid or new_hwid == "" then new_hwid = sys_hwid end
    if not new_dev_os or new_dev_os == "" then new_dev_os = sys_os end
    if not new_dev_model or new_dev_model == "" then new_dev_model = sys_model end

    uci:section("subconv", "subscription", new_id, {
        enabled = "1",
        url = new_url,
        user_agent = new_ua,
        hwid = new_hwid,
        device_os = new_dev_os,
        device_model = new_dev_model,
        interval = "1440"
    })
    uci:delete("subconv", "new", "sub_id")
    uci:delete("subconv", "new", "url")
    uci:delete("subconv", "new", "user_agent")
    uci:delete("subconv", "new", "hwid")
    uci:delete("subconv", "new", "device_os")
    uci:delete("subconv", "new", "device_model")
    uci:commit("subconv")

    local ret = sys.call("/usr/libexec/subconv-update.sh " .. new_id)
    if ret == 0 then
        m.message = "✅ УСПЕХ: Подписка [" .. new_id .. "] добавлена, файл /www/" .. new_id .. ".txt заполнен."
    else
        m.message = "❌ ОШИБКА: Не удалось получить узлы для [" .. new_id .. "]. См. /www/subconv_debug.txt"
    end
end

local s_add = m:section(NamedSection, "new", "dummy", translate("Добавить новую подписку"))
s_add.addremove = false

local f_id = s_add:option(Value, "sub_id", translate("Имя подписки (ID)"))
f_id.rmempty = true
f_id.description = translate("Уникальное имя. Имя файла будет совпадать ({name}.txt).")
f_id.cfgvalue = function() return "" end

local f_url = s_add:option(Value, "url", translate("URL подписки"))
f_url.rmempty = true
f_url.cfgvalue = function() return "" end

local f_ua = s_add:option(Value, "user_agent", translate("User-Agent"))
f_ua.default = "mihomo"
f_ua.cfgvalue = function() return "mihomo" end

local f_hwid = s_add:option(Value, "hwid", translate("HWID устройства"))
f_hwid.default = sys_hwid
f_hwid.cfgvalue = function() return sys_hwid end

local f_dev_os = s_add:option(Value, "device_os", translate("OS Устройства"))
f_dev_os.default = sys_os
f_dev_os.cfgvalue = function() return sys_os end

local f_dev_model = s_add:option(Value, "device_model", translate("Модель Устройства"))
f_dev_model.default = sys_model
f_dev_model.cfgvalue = function() return sys_model end

local btn_add = s_add:option(Button, "_add", translate("Добавить подписку"))
btn_add.inputstyle = "add"

local s_list = m:section(TypedSection, "subscription", translate("Активные подписки"))
s_list.addremove = false
s_list.anonymous = false
s_list.template = "cbi/tblsection"

s_list:option(Flag, "enabled", translate("Вкл")).rmempty = false
s_list:option(Value, "url", translate("URL")).rmempty = false
s_list:option(Value, "user_agent", translate("User-Agent")).rmempty = false
s_list:option(Value, "hwid", translate("HWID")).rmempty = false
s_list:option(Value, "device_os", translate("ОС")).rmempty = false
s_list:option(Value, "device_model", translate("Модель")).rmempty = false

local list_interval = s_list:option(Value, "interval", translate("Мин."))
list_interval.datatype = "uinteger"
list_interval.default = "1440"

local list_link = s_list:option(DummyValue, "_link", translate("Локальная ссылка"))
function list_link.cfgvalue(self, section)
    return "http://127.0.0.1/" .. section .. ".txt"
end

local btn_upd = s_list:option(Button, "_update", translate("Обновить"))
btn_upd.inputstyle = "apply"
function btn_upd.write(self, section)
    local r = sys.call("/usr/libexec/subconv-update.sh " .. section)
    if r == 0 then
        m.message = "✅ Подписка [" .. section .. "] успешно обновлена."
    else
        m.message = "❌ Ошибка при обновлении подписки [" .. section .. "]. См. /www/subconv_debug.txt"
    end
end

local btn_del = s_list:option(Button, "_delete", translate("Удалить"))
btn_del.inputstyle = "remove"
function btn_del.write(self, section)
    uci:delete("subconv", section)
    uci:commit("subconv")
    os.execute("rm -f /www/" .. section .. ".txt")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
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
