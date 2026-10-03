#!/bin/sh

echo "========================================================="
echo "        Установка Subconv (Обновить все + UI)            "
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
    
    echo "✅ Плагин полностью удален!"
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    opkg update
    opkg install curl
fi

mkdir -p /usr/libexec
mkdir -p /usr/lib/lua/luci/model/cbi
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/share/luci/menu.d
mkdir -p /usr/share/rpcd/acl.d

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
if not sub_id then os.exit(1) end

uci:load("subconv")
local url = uci:get("subconv", sub_id, "url")
local ua = uci:get("subconv", sub_id, "user_agent") or "SubConv/1.0"
local hwid = uci:get("subconv", sub_id, "hwid") or "openwrt-router-default"
local dev_os = uci:get("subconv", sub_id, "device_os") or "OpenWrt"
local dev_model = uci:get("subconv", sub_id, "device_model") or "OpenWrt Router"

if not url or url == "" then
    save_status("Ошибка: нет URL")
    os.exit(1)
end

local out_path = "/www/" .. sub_id .. ".txt"

log("Запрос: " .. url)
log("Заголовки: UA=" .. ua .. " | HWID=" .. hwid .. " | OS=" .. dev_os)

local cmd = string.format("curl -k -L -s -w '%%{http_code}' --connect-timeout 10 --max-time 30 -A %s -H %s -H %s -H %s %s",
    util.shellquote(ua),
    util.shellquote("X-HWID: " .. hwid),
    util.shellquote("X-DEVICE-OS: " .. dev_os),
    util.shellquote("X-DEVICE-MODEL: " .. dev_model),
    util.shellquote(url)
)

local handle = io.popen(cmd)
local resp_raw = handle:read("*all")
handle:close()

if not resp_raw or #resp_raw < 3 then
    log("ОШИБКА: Сервер не ответил (сбой сети или таймаут)")
    save_status("Ошибка сети")
    os.exit(1)
end

local http_code = resp_raw:sub(-3)
local resp = resp_raw:sub(1, -4)

log("HTTP Код: " .. tostring(http_code))

if #resp == 0 then
    log("ОШИБКА: Пустое тело ответа")
    save_status("Ошибка (HTTP " .. http_code .. "/Пусто)")
else
    local decoded = resp
    local is_b64 = false
    local maybe_decoded = nixio.bin.b64decode(resp)
    
    if maybe_decoded then
        if maybe_decoded:match("://") or maybe_decoded:match("^%s*{") or maybe_decoded:match("^%s*%[") or maybe_decoded:match("proxies:") then
            decoded = maybe_decoded
            is_b64 = true
            log("Декодирован Base64")
        end
    end

    local is_raw = false
    if decoded:match("^%s*{") or decoded:match("^%s*%[") or decoded:match("proxies:") then
        is_raw = true
    end

    if is_raw then
        local f_out = io.open(out_path, "w")
        if f_out then
            f_out:write(decoded)
            f_out:close()
            log("УСПЕХ: Сохранен как сырой конфиг (JSON/YAML)")
            save_status("JSON/YAML Конфиг")
        else
            log("ОШИБКА: Не удалось записать файл " .. out_path)
            save_status("Ошибка записи")
        end
    else
        local links = {}
        for line in decoded:gmatch("[^\r\n]+") do
            line = line:match("^%s*(.-)%s*$")
            if line and line:match("://") then 
                table.insert(links, line) 
            end
        end

        if #links > 0 then
            local f_out = io.open(out_path, "w")
            if f_out then
                f_out:write(table.concat(links, "\n") .. "\n")
                f_out:close()
                log("УСПЕХ: Найдено " .. #links .. " узлов URI")
                if is_b64 then save_status("Base64 URI (" .. #links .. ")") else save_status("Текст URI (" .. #links .. ")") end
            else
                save_status("Ошибка записи")
            end
        else
            local snippet = decoded:sub(1, 50):gsub("[%c\n\r]", " ")
            log("ОШИБКА: Узлы не найдены. Начало ответа: " .. snippet)
            save_status("Пусто (Нет узлов)")
        end
    end
end

if f_dbg then f_dbg:close() end
EOF
chmod +x /usr/libexec/subconv-update.sh

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

local random_hwid = sys.exec("cat /proc/sys/kernel/random/uuid 2>/dev/null"):gsub("-", ""):gsub("%s+", ""):sub(1, 16)
if not random_hwid or random_hwid == "" then random_hwid = "happ" .. tostring(os.time()) end

sys_os = sys_os:gsub("[\r\n]", "")
sys_model = sys_model:gsub("[\r\n]", "")
sys_hwid = sys_hwid:gsub("[\r\n]", "")

local s_add = m:section(NamedSection, "add", "global", translate("Добавить новую подписку"))
s_add.addremove = false
s_add.anonymous = true

local f_id = s_add:option(Value, "sub_id", translate("Имя подписки (ID)"))
f_id.description = translate("Только латиница без пробелов. Задает имя выходного файла ({ID}.txt).")
f_id.rmempty = true

local f_url = s_add:option(Value, "url", translate("URL подписки"))
f_url.description = translate("Прямая ссылка от провайдера (поддерживаются форматы URI, YAML и JSON).")
f_url.rmempty = true

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

local f_js = s_add:option(DummyValue, "_js_tweaks")
f_js.rawhtml = true
function f_js.cfgvalue()
    return [[
        <script>
            setTimeout(function() {
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
            }, 100);
        </script>
    ]]
end

local btn_add = s_add:option(Button, "_add", "")
btn_add.inputtitle = translate("➕ Добавить подписку")
btn_add.inputstyle = "add"
function btn_add.write(self, section)
    local new_id = m:formvalue("cbid.subconv.add.sub_id")
    local new_url = m:formvalue("cbid.subconv.add.url")
    local new_ua = m:formvalue("cbid.subconv.add.user_agent") or "SubConv/1.0"
    local new_interval = m:formvalue("cbid.subconv.add.interval") or "1440"
    local new_hwid_val = m:formvalue("cbid.subconv.add.hwid") or random_hwid
    local new_os = m:formvalue("cbid.subconv.add.device_os") or sys_os
    local new_model = m:formvalue("cbid.subconv.add.device_model") or sys_model

    if new_id and new_id ~= "" and new_url and new_url ~= "" then
        new_id = string.gsub(new_id, "[^%w_]", "_")
        
        if uci:get("subconv", new_id) then
            m.message = "Ошибка: Подписка с именем '" .. new_id .. "' уже существует!"
            return
        end

        uci:section("subconv", "subscription", new_id, {
            enabled = "1", url = new_url, user_agent = new_ua,
            hwid = new_hwid_val, device_os = new_os, device_model = new_model,
            interval = new_interval, last_type = "Ожидание..."
        })
        uci:set("subconv", "add", "sub_id", "")
        uci:set("subconv", "add", "url", "")
        uci:commit("subconv")
        
        sys.call("/usr/libexec/subconv-update.sh " .. util.shellquote(new_id) .. " >/dev/null 2>&1 &")
        http.redirect(dsp.build_url("admin", "services", "subconv"))
    end
end

local list_title = translate("Активные подписки") .. [[ <button type="submit" name="update_all" value="1" class="cbi-button cbi-button-apply" style="margin-left: 15px; font-size: 12px; padding: 4px 12px;">🔄 Обновить все</button> <span style="font-weight: normal; font-size: 12px; opacity: 0.7; margin-left: 10px;">(процесс может занять некоторое время)</span>]]
local s_list = m:section(TypedSection, "subscription", list_title)
s_list.anonymous = true
s_list.addremove = false
s_list.template = "cbi/tblsection"

local en = s_list:option(Flag, "enabled", translate("Вкл"))
en.rmempty = false
en.default = "1"
en.enabled = "1"
en.disabled = "0"

local url_list = s_list:option(DummyValue, "url", translate("URL"))
url_list.rawhtml = true
function url_list.cfgvalue(self, section)
    local val = uci:get("subconv", section, "url") or ""
    return string.format('<div style="word-break: break-all; min-width: 200px; font-size: 11px; line-height: 1.2;">%s</div>', val)
end

local ua_list = s_list:option(Value, "user_agent", translate("User-Agent"))
ua_list.size = "12"
ua_list:value("SubConv/1.0", "SubConv/1.0")
ua_list:value("sing-box/1.9.3", "sing-box 1.9.3")
ua_list:value("mihomo/1.18.3", "mihomo 1.18.3")
ua_list:value("Happ/SC", "Happ/SC")
ua_list.rmempty = false

local hwid_opt = s_list:option(DummyValue, "hwid", translate("HWID"))
hwid_opt.rawhtml = true
function hwid_opt.cfgvalue(self, section)
    local val = uci:get("subconv", section, "hwid") or ""
    return string.format('<div style="word-break: break-all; font-family: monospace; font-size: 11px; line-height: 1.2; min-width: 100px;">%s</div>', val)
end

local os_opt = s_list:option(DummyValue, "device_os", translate("OS"))
os_opt.rawhtml = true
function os_opt.cfgvalue(self, section)
    return string.format('<div style="font-size: 11px;">%s</div>', uci:get("subconv", section, "device_os") or "")
end

local model_opt = s_list:option(DummyValue, "device_model", translate("Модель"))
model_opt.rawhtml = true
function model_opt.cfgvalue(self, section)
    return string.format('<div style="font-size: 11px;">%s</div>', uci:get("subconv", section, "device_model") or "")
end

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

local link_opt = s_list:option(DummyValue, "_link", translate("Название (ID) и ссылка"))
link_opt.rawhtml = true
function link_opt.cfgvalue(self, section)
    local display_url = "http://127.0.0.1/" .. section .. ".txt"
    local href_url = "/" .. section .. ".txt"
    return string.format('<div style="line-height: 1.4; white-space: nowrap;"><b>%s</b><br><a href="%s" target="_blank" title="Открыть файл">%s</a></div>', section, href_url, display_url)
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

local btn_del_list = s_list:option(Button, "_delete", translate(" "))
btn_del_list.inputtitle = "🗑️"
btn_del_list.inputstyle = "remove"
function btn_del_list.write(self, section)
    os.execute("rm -f " .. util.shellquote("/www/" .. section .. ".txt"))
    uci:delete("subconv", section)
    uci:commit("subconv")
    http.redirect(dsp.build_url("admin", "services", "subconv"))
end

local s_log = m:section(TypedSection, "global", translate("Журнал отладки"))
s_log.anonymous = true
s_log.addremove = false
function s_log.filter(self, section) return section == "add" end

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
    local content = f and f:read("*all") or "Лог пуст. Нажмите 🔄 на любой подписке."
    if f then f:close() end
    content = content:gsub("<", "&lt;"):gsub(">", "&gt;")
    return string.format('<textarea readonly wrap="off" style="width: 100%%; height: 350px; background: #1a1b26; color: #a9b1d6; font-family: monospace; font-size: 13px; padding: 10px; border: 1px solid #333; margin-top: 10px;">%s</textarea><script>setTimeout(function(){var t=document.getElementsByTagName("textarea");var l=t[t.length-1];if(l){l.scrollTop=l.scrollHeight;}}, 100);</script>', content)
end

function m.on_after_commit(self)
    sys.call("/usr/libexec/subconv-cron.sh")
end

if http.formvalue("update_all") == "1" then
    uci:foreach("subconv", "subscription", function(s)
        uci:set("subconv", s['.name'], "last_type", "Обновление...")
        sys.call("/usr/libexec/subconv-update.sh " .. util.shellquote(s['.name']) .. " >/dev/null 2>&1 &")
    end)
    uci:commit("subconv")
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
