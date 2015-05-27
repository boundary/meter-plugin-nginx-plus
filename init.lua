local framework = require('framework')
local json = require('json')
local url = require('url')
local table = require('table')
local Plugin  = framework.Plugin
local WebRequestDataSource = framework.WebRequestDataSource
local Accumulator = framework.Accumulator
local auth = framework.util.auth
local gsplit = framework.string.gsplit
local pack = framework.util.pack

local params = framework.params
params.pollInterval = (params.pollSeconds and tonumber(params.pollSeconds)*1000) or params.pollInterval or 1000
params.name = 'Boundary NGINX Plus Plugin'
params.version = '1.0' 
params.tags = 'nginx+' 

function addToSet(set, key)
  if key and key ~= "" then
    set[key] = true
  end
end

function removeFromSet(set, key)
  if key and key ~= "" then
    set[key] = nil
  end
end

function setContains(set, key)
  if set then
    return set[key] ~= nil
  else
    return true
  end
end

local server_zones = {}
local TCP_server_zones = {}
local caches = {}
local upstreams = {}
local TCP_upstreams = {}

server_zones = params.zones or server_zones
TCP_server_zones = params.tcpzones or TCP_server_zones
caches = params.caches or caches
upstreams = params.upstreams or upstreams
TCP_upstreams = params.tcpupstreams or TCP_upstreams

local options = url.parse(params.url)
options.auth = auth(params.username, params.password) 
options.wait_for_end = true
local ds = WebRequestDataSource:new(options)
local acc = Accumulator:new()
local plugin = Plugin:new(params, ds)

for _, server_zone in pairs(server_zones) do
  addToSet(plugin.zones_to_check, server_zone)
end
for _, TCP_server_zone in pairs(TCP_server_zones) do
  addToSet(plugin.tcpzones_to_check, TCP_server_zone)
end
for _, cache in pairs(caches) do
  addToSet(plugin.caches_to_check, cache)
end
for _, upstream in pairs(upstreams) do
  addToSet(plugin.upstreams_to_check, upstream)
end
for _, TCP_upstream in pairs(TCP_upstreams) do
  addToSet(plugin.tcpupstreams_to_check, TCP_upstream)
end

local function parseJson(body)
    local parsed
    pcall(function () parsed = json.parse(body) end)
    return parsed 
end

function plugin:onParseValues(data)
  local metrics = {}

  local stats = parseJson(data)
  if stats then
    local handled = stats['connections']['accepted'] - stats['connections']['dropped']
    local requests = stats['requests']['total']
    local reqs_per_connection = (handled > 0) and requests / handled or 0

    metrics['NGINX_PLUS_ACTIVE_CONNECTIONS'] = stats['connections']['active'] + stats['connections']['idle']
    metrics['NGINX_PLUS_WAITING'] = stats['connections']['idle']
    metrics['NGINX_PLUS_HANDLED'] = acc:accumulate('handled', handled)
    metrics['NGINX_PLUS_NOT_HANDLED'] = stats['connections']['dropped']
    metrics['NGINX_PLUS_REQUESTS'] = acc:accumulate('requests', requests)
    metrics['NGINX_PLUS_CURRENT_REQUESTS'] = stats['requests']['current']
    metrics['NGINX_PLUS_REQUESTS_PER_CONNECTION'] = reqs_per_connection
    metrics['NGINX_PLUS_UPTIME'] = tonumber(stats['timestamp']) - tonumber(stats['load_timestamp'])
    for cache_name, cache in pairs(stats.caches) do
      if setContains(self.caches_to_check, cache_name) then
        local src = self.source .. '.' .. cache_name
        local served = tonumber(cache['hit']['bytes'])+tonumber(cache['stale']['bytes'])+tonumber(cache['updating']['bytes'])+tonumber(cache['revalidated']['bytes'])
        local bypassed = tonumber(cache['miss']['bytes'])+tonumber(cache['expired']['bytes'])+tonumber(cache['bypass']['bytes'])
        table.insert(metrics, pack('NGINX_PLUS_CACHE_COLD', cache['cold'] and 1 or 0, nil, src))
        table.insert(metrics, pack('NGINX_PLUS_CACHE_SIZE', cache['size'], nil, src))
        table.insert(metrics, pack('NGINX_PLUS_CACHE_USED', cache['size']/cache['max_size'], nil, src))
        table.insert(metrics, pack('NGINX_PLUS_CACHE_SERVED', served, nil, src))
        table.insert(metrics, pack('NGINX_PLUS_CACHE_WRITTEN', tonumber(cache['miss']['bytes_written'])+tonumber(cache['expired']['bytes_written'])+tonumber(cache['bypass']['bytes_written']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_CACHE_BYPASSED', bypassed, nil, src))
        table.insert(metrics, pack('NGINX_PLUS_CACHE_HIT_PERCENT', served/(served+bypassed), nil, src))
      end
    end
    for zone_name, zone in pairs(stats.server_zones) do
      if setContains(self.zones_to_check, zone_name) then
        local src = self.source .. '.' .. zone_name
        table.insert(metrics, pack('NGINX_PLUS_ZONE_CURRENT_REQUESTS', zone['processing'], nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_REQUESTS', acc:accumulate('requests_' .. zone_name, zone['requests']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_1XX_RESPONSES', acc:accumulate('responses_' .. zone_name, zone['responses']['1xx']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_2XX_RESPONSES', acc:accumulate('responses_' .. zone_name, zone['responses']['2xx']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_3XX_RESPONSES', acc:accumulate('responses_' .. zone_name, zone['responses']['3xx']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_4XX_RESPONSES', acc:accumulate('responses_' .. zone_name, zone['responses']['4xx']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_5XX_RESPONSES', acc:accumulate('responses_' .. zone_name, zone['responses']['5xx']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_TOTAL_RESPONSES', acc:accumulate('responses_' .. zone_name, zone['responses']['total']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_TRAFFIC_SENT', acc:accumulate('traffic_sent_' .. zone_name, zone['sent']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_TRAFFIC_RECEIVED', acc:accumulate('traffic_received_' .. zone_name, zone['received']), nil, src))
      end
    end
    for upstream_name, upstream_array in pairs(stats.upstreams) do
      if setContains(self.upstreams_to_check, upstream_name) then
        for _, upstream in pairs(upstream_array) do
          local backup = upstream['backup'] and ".b_" or "."
          local src = self.source .. '.' .. upstream_name .. backup .. upstream['server']
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_STATE', (string.upper(upstream['state']) == 'UP' and 0) or (string.upper(upstream['state']) == 'DRAINING' and 1) or (string.upper(upstream['state']) == 'DOWN' and 2) or (string.upper(upstream['state']) == 'UNAVAIL' and 3) or (string.upper(upstream['state']) == 'UNHEALTHY' and 4) or 5, nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_REQUESTS', acc:accumulate('responses_' .. upstream_name, upstream['requests']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_1XX_RESPONSES', acc:accumulate('responses_' .. upstream_name, upstream['responses']['1xx']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_2XX_RESPONSES', acc:accumulate('responses_' .. upstream_name, upstream['responses']['2xx']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_3XX_RESPONSES', acc:accumulate('responses_' .. upstream_name, upstream['responses']['3xx']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_4XX_RESPONSES', acc:accumulate('responses_' .. upstream_name, upstream['responses']['4xx']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_5XX_RESPONSES', acc:accumulate('responses_' .. upstream_name, upstream['responses']['5xx']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_TOTAL_RESPONSES', acc:accumulate('responses_' .. upstream_name, upstream['responses']['total']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_ACTIVE_CONNECTIONS', upstream['active'], nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_PERC_USED_CONNECTIONS', (upstream['max_conns'] and tonumber(upstream['max_conns']) > 0) and tonumber(upstream['active'])/tonumber(upstream['max_conns']) or 0, nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_TRAFFIC_SENT', acc:accumulate('traffic_sent_' .. upstream_name, upstream['sent']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_TRAFFIC_RECEIVED', acc:accumulate('traffic_received_' .. upstream_name, upstream['received']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_FAILED_CHECKS', upstream['fails'], nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_DOWNTIME', upstream['downtime'], nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_PERC_FAILED', tonumber(upstream['health_checks']['fails'])/tonumber(upstream['health_checks']['checks']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_HEALTHY', upstream['health_checks']['last_passed'] and 1 or 0, nil, src))
        end
      end
    end
    for TCP_zone_name, TCP_zone in pairs(stats.stream.server_zones) do
      if setContains(self.tcpzones_to_check, TCP_zone_name) then
        local src = self.source .. '.' .. TCP_zone_name
        table.insert(metrics, pack('NGINX_PLUS_TCPZONE_CURRENT_CONNECTIONS', TCP_zone['processing'], nil, src))
        table.insert(metrics, pack('NGINX_PLUS_TCPZONE_CONNECTIONS', acc:accumulate('connections_' .. TCP_zone_name, TCP_zone['connections']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_TCPZONE_TRAFFIC_SENT', acc:accumulate('traffic_sent_' .. TCP_zone_name, TCP_zone['sent']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_TCPZONE_TRAFFIC_RECEIVED', acc:accumulate('traffic_received_' .. TCP_zone_name, TCP_zone['received']), nil, src))
      end
    end
    for TCP_upstream_name, TCP_upstream_array in pairs(stats.stream.upstreams) do
      if setContains(self.tcpupstreams_to_check, TCP_upstream_name) then
        for _, TCP_upstream in pairs(TCP_upstream_array) do
          local backup = TCP_upstream['backup'] and ".b_" or "."
          local src = self.source .. '.' .. TCP_upstream_name .. backup .. TCP_upstream['server']
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_STATE', (string.upper(TCP_upstream['state']) == 'UP' and 0) or (string.upper(TCP_upstream['state']) == 'DRAINING' and 1) or (string.upper(TCP_upstream['state']) == 'DOWN' and 2) or (string.upper(TCP_upstream['state']) == 'UNAVAIL' and 3) or (string.upper(TCP_upstream['state']) == 'UNHEALTHY' and 4) or 5, nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_CONNECTIONS', acc:accumulate('connections_' .. TCP_upstream_name, TCP_upstream['connections']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_ACTIVE_CONNECTIONS', TCP_upstream['active'], nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_PERC_USED_CONNECTIONS', (TCP_upstream['max_conns'] and tonumber(TCP_upstream['max_conns']) > 0) and tonumber(TCP_upstream['active'])/tonumber(TCP_upstream['max_conns']) or 0, nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_TRAFFIC_SENT', acc:accumulate('traffic_sent_' .. TCP_upstream_name, TCP_upstream['sent']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_TRAFFIC_RECEIVED', acc:accumulate('traffic_received_' .. TCP_upstream_name, TCP_upstream['received']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_FAILED_CHECKS', TCP_upstream['fails'], nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_DOWNTIME', TCP_upstream['downtime'], nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_PERC_FAILED', tonumber(TCP_upstream['health_checks']['fails'])/tonumber(TCP_upstream['health_checks']['checks']), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_HEALTHY', TCP_upstream['health_checks']['last_passed'] and 1 or 0, nil, src))
          if TCP_upstream['connect_time'] then
            table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_CONNECT_TIME', TCP_upstream['connect_time'], nil, src))
          end
          if TCP_upstream['first_byte_time'] then
            table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_FIRST_BYTE_TIME', TCP_upstream['first_byte_time'], nil, src))
          end
          if TCP_upstream['response_time'] then
            table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_RESPONSE_TIME', TCP_upstream['response_time'], nil, src))
          end
        end
      end
    end
  end

  return metrics 
end

plugin:run()
