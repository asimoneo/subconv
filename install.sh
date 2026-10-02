#!/bin/sh

echo "========================================================="
echo "        Установка SubConv (Конвертер подписок)           "
echo "========================================================="
echo "Выберите действие:"
echo " 1) Установить / Обновить плагин"
echo " 2) Полностью УДАЛИТЬ плагин и все его файлы"
echo "========================================================="
printf "Ваш выбор [1]: "
read action

if [ "$action" = "2" ]; then
    echo "Удаление SubConv..."
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
    echo "✅ Плагин, его конфигурация и интерфейс полностью удалены!"
    exit 0
fi

echo "1. Создание системных директорий..."
mkdir -p /usr/libexec
mkdir -p /usr/lib/lua/luci/model/cbi
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/share/luci/menu.d
mkdir -p /usr/share/rpcd/acl.d

echo "2. Создание скрипта обновления..."
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
local ua = uci:get("subconv", sub_id, "user_agent") or "SubConv/1.0"
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

local function decodeBase64(data)
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    data = string.gsub(data, '[^'..b..'=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r,f='',(b:find(x)-1)
        for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
        return r
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then return '' end
        local c=0
        for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
end

local decoded = resp
local maybe_decoded = decodeBase64(resp)
if maybe_decoded and maybe_decoded:match("://") then
    decoded = maybe_decoded
    log("Base64 успешно декодирован")
else
    log("Используем ответ как открытый текст")
end

local links = {}
for line in decoded:gmatch("[^\r\n]+") do
    if line:match("://") then
        table.insert(links, line)
    end
end

log("Найдено узлов прокси: " .. #links)

if #links > 0 then
    local out_path = "/www/" .. sub_id .. ".txt"
    local f_out = io.open(out_path, "w")
    if f_out then
        f_out:write(table.concat(links, "\n") .. "\n")
        f_out:close()
        log("УСПЕХ: записано в " .. out_path)
        if f_dbg then f_dbg:close() end
        os.exit(0)
    else
        log("Ошибка записи в файл " .. out_path)
        if f_dbg then f_dbg:close() end
        os.exit(1)
    end
else
    log("ОШИБКА: не найдено ни одного узла")
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

echo "4. Создание меню для LuCI (/usr/share/luci/menu.d/subconv.json)..."
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

local m = Map("subconv", translate("Конвертер подписок (SubConv)"), translate("Парсинг YAML-подписок и конвертация в списки для HomeProxy."))

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
local f_hwid = io.open("/etc/machine-id", "r")
if f_hwid then
    local hw = f_hwid:read("*all"):gsub("^%s+", ""):gsub("%s+$", "")
    if hw ~= "" then sys_hwid = hw end
    f_hwid:close()
end

local s_add = m:section(NamedSection, "add", "global", translate("Добавить новую подписку"))
s_add.addremove = false
s_add.anonymous = true

local f_id = s_add:option(Value, "sub_id", translate("Имя подписки (ID)"))
f_id.description = translate("Уникальное имя. Имя файла будет совпадать ({name}.txt).")
f_id.rmempty = true

local f_url = s_add:option(Value, "url", translate("URL подписки"))
f_url.rmempty = true

local f_ua = s_add:option(Value, "user_agent", translate("User-Agent"))
f_ua.default = "SubConv/1.0"
f_ua.rmempty = true

local f_hwid_opt = s_add:option(Value, "hwid", translate("HWID устройства"))
f_hwid_opt.default = sys_hwid
f_hwid_opt.rmempty = true

local f_os = s_add:option(Value, "device_os", translate("OS Устройства"))
f_os.default = sys_os
f_os.rmempty = true

local f_model = s_add:option(Value, "device_model", translate("Модель Устройства"))
f_model.default = sys_model
f_model.rmempty = true

local btn_add = s_add:option(Button, "_add", translate("Добавить подписку"))
btn_add.inputstyle = "add"
function btn_add.write(self, section)
    local new_id = m:formvalue("cbid.subconv.add.sub_id")
    local new_url = m:formvalue("cbid.subconv.add.url")
    local new_ua = m:formvalue("cbid.subconv.add.user_agent") or "SubConv/1.0"
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
            interval = "1440"
        })
        uci:set("subconv", "add", "sub_id", "")
        uci:set("subconv", "add", "url", "")
        uci:commit("subconv")
        sys.call("/usr/libexec/subconv-update.sh " .. new_id)
        http.redirect(dsp.build_url("admin", "services", "subconv"))
    end
end

local s_list = m:section(TypedSection, "subscription", translate("Активные подписки"))
s_list.anonymous = false
s_list.addremove = false
s_list.template = "cbi/tblsection"

s_list:option(Flag, "enabled", translate("Вкл")).rmempty = false
s_list:option(Value, "url", translate("URL")).rmempty = false
s_list:option(Value, "user_agent", translate("User-Agent")).rmempty = false
s_list:option(Value, "hwid", translate("HWID")).rmempty = false
s_list:option(Value, "device_os", translate("ОС")).rmempty = false
s_list:option(Value, "device_model", translate("Модель")).rmempty = false

local interval_opt = s_list:option(Value, "interval", translate("Мин."))
interval_opt.datatype = "uinteger"
interval_opt.rmempty = false

local link_opt = s_list:option(DummyValue, "_link", translate("Локальная ссылка"))
function link_opt.cfgvalue(self, section)
    return "http://127.0.0.1/" .. section .. ".txt"
end

local btn_upd_list = s_list:option(Button, "_update", translate("Обновить"))
btn_upd_list.inputstyle = "apply"
function btn_upd_list.write(self, section)
    sys.call("/usr/libexec/subconv-update.sh " .. section)
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

local btn_del_list = s_list:option(Button, "_delete", translate("Удалить"))
btn_del_list.inputstyle = "remove"
function btn_del_list.write(self, section)
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
    cat << 'EOF' > /etc/config/subconv
config global 'add'
EOF
fi

echo "9. Очистка кэша LuCI..."
rm -rf /tmp/luci-* /tmp/rpcd-* /tmp/state/*
/etc/init.d/rpcd restart

echo "=========================================="
echo "✅ Установка успешно завершена!"
echo "Перейдите в веб-интерфейс LuCI -> Службы -> Конвертер подписок (SubConv)"
echo "=========================================="
