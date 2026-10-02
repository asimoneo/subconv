#!/bin/sh

echo "=== Установка SubConv (OpenWrt 25.12 Compatible) ==="

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

local m = Map("subconv", translate("Конвертер подписок (SubConv)"), 
    translate("Парсинг подписок и конвертация для HomeProxy."))

local s = m:section(TypedSection, "subscription", translate("Управление подписками"))
s.anonymous = false
s.addremove = true
s.template = "cbi/tblsection"

s:option(Flag, "enabled", translate("Вкл"))
s:option(Value, "url", translate("URL подписки"))
s:option(Value, "user_agent", translate("User-Agent"))
s:option(Value, "interval", translate("Интервал"))

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
        m.message = "❌ Ошибка при обновлении. См. /www/subconv_debug.txt"
    end
end

function m.on_after_commit(self)
    sys.call("/usr/libexec/subconv-cron.sh")
end

return m
EOF

echo "8. Создание конфигурационного файла UCI (/etc/config/subconv) с начальным примером..."
cat << 'EOF' > /etc/config/subconv
config subscription 'my_sub'
    option enabled '1'
    option url 'https://example.com/sub'
    option user_agent 'mihomo'
    option interval '1440'
EOF

echo "9. Очистка кэша LuCI..."
rm -rf /tmp/luci-* /tmp/rpcd-* /tmp/state/*
/etc/init.d/rpcd restart

echo "=========================================="
echo "✅ Установка успешно завершена!"
echo "Перейдите в веб-интерфейс LuCI -> Службы -> Конвертер подписок (SubConv)"
echo "=========================================="
