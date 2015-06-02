local framework = require('framework')
local fs = require('fs')
local json = require('json')
local url = require('url')
local table = require('table')
local Plugin  = framework.Plugin
local WebRequestDataSource = framework.WebRequestDataSource
local Accumulator = framework.Accumulator
local auth = framework.util.auth
local gsplit = framework.string.gsplit
local pack = framework.util.pack

local params = framework.params or {}
if framework.plugin_params.name == nil then
  params.name = 'Boundary NGINX+ Plugin'
  params.version = '1.1' 
  params.tags = 'nginx+' 
end

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
    local reqs_per_connection = (handled > 0 and requests/handled) or 0

    metrics['NGINX_PLUS_ACTIVE_CONNECTIONS'] = stats['connections']['active'] + stats['connections']['idle']
    metrics['NGINX_PLUS_WAITING'] = stats['connections']['idle']
    metrics['NGINX_PLUS_HANDLED'] = acc:accumulate('handled', handled)/(params.pollInterval/1000)
    metrics['NGINX_PLUS_NOT_HANDLED'] = stats['connections']['dropped']
    metrics['NGINX_PLUS_REQUESTS'] = acc:accumulate('requests', requests)/(params.pollInterval/1000)
    metrics['NGINX_PLUS_CURRENT_REQUESTS'] = stats['requests']['current']
    metrics['NGINX_PLUS_REQUESTS_PER_CONNECTION'] = reqs_per_connection
    metrics['NGINX_PLUS_UPTIME'] = tonumber(stats['timestamp']) - tonumber(stats['load_timestamp'])
    for cache_name, cache in pairs(stats.caches) do
      if setContains(self.caches_to_check, cache_name) then
        local src = self.source .. '.' .. string.gsub(cache_name, ":", "_")
        local served = tonumber(cache['hit']['bytes'])+tonumber(cache['stale']['bytes'])+tonumber(cache['updating']['bytes'])+tonumber(cache['revalidated']['bytes'])
        local bypassed = tonumber(cache['miss']['bytes'])+tonumber(cache['expired']['bytes'])+tonumber(cache['bypass']['bytes'])

        table.insert(metrics, pack('NGINX_PLUS_CACHE_COLD', cache['cold'] and 1 or 0, nil, src))
        if params.cache_cold_event then
          local cold_change = acc:accumulate('caches_cold_' .. cache_name, cache['cold'] and 1 or 0)

          if cold_change ~= 0 then
            if cache['cold'] then
              plugin:printWarn('Cache Cold', self.source, src, string.format('Cache %s is now %s|h:%s|s:%s', cache_name, 'Cold'))
            else
              plugin:printInfo('Cache Cold', self.source, src, string.format('Cache %s is now %s|h:%s|s:%s', cache_name, 'Warm'))
            end
          end
        end
        table.insert(metrics, pack('NGINX_PLUS_CACHE_SIZE', cache['size'], nil, src))
        if tonumber(cache['max_size']) == 0 then
          table.insert(metrics, pack('NGINX_PLUS_CACHE_USED', 0, nil, src))
        else
          table.insert(metrics, pack('NGINX_PLUS_CACHE_USED', tonumber(cache['size'])/tonumber(cache['max_size']), nil, src))
        end
        table.insert(metrics, pack('NGINX_PLUS_CACHE_SERVED', served, nil, src))
        table.insert(metrics, pack('NGINX_PLUS_CACHE_WRITTEN', tonumber(cache['miss']['bytes_written'])+tonumber(cache['expired']['bytes_written'])+tonumber(cache['bypass']['bytes_written']), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_CACHE_BYPASSED', bypassed, nil, src))
        if served+bypassed == 0 then
          table.insert(metrics, pack('NGINX_PLUS_CACHE_HIT_PERCENT', 0, nil, src))
        else
          table.insert(metrics, pack('NGINX_PLUS_CACHE_HIT_PERCENT', served/(served+bypassed), nil, src))
        end
      end
    end
    for zone_name, zone in pairs(stats.server_zones) do
      if setContains(self.zones_to_check, zone_name) then
        local src = self.source .. '.' .. string.gsub(zone_name, ":", "_")
        table.insert(metrics, pack('NGINX_PLUS_ZONE_CURRENT_REQUESTS', zone['processing'], nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_REQUESTS', acc:accumulate('zone_requests_' .. zone_name, zone['requests'])/(params.pollInterval/1000), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_1XX_RESPONSES', acc:accumulate('zone_1xx_responses_' .. zone_name, zone['responses']['1xx'])/(params.pollInterval/1000), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_2XX_RESPONSES', acc:accumulate('zone_2xx_responses_' .. zone_name, zone['responses']['2xx'])/(params.pollInterval/1000), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_3XX_RESPONSES', acc:accumulate('zone_3xx_responses_' .. zone_name, zone['responses']['3xx'])/(params.pollInterval/1000), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_4XX_RESPONSES', acc:accumulate('zone_4xx_responses_' .. zone_name, zone['responses']['4xx'])/(params.pollInterval/1000), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_5XX_RESPONSES', acc:accumulate('zone_5xx_responses_' .. zone_name, zone['responses']['5xx'])/(params.pollInterval/1000), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_TOTAL_RESPONSES', acc:accumulate('zone_total_responses_' .. zone_name, zone['responses']['total'])/(params.pollInterval/1000), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_TRAFFIC_SENT', acc:accumulate('zone_traffic_sent_' .. zone_name, zone['sent'])/(params.pollInterval/1000), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_ZONE_TRAFFIC_RECEIVED', acc:accumulate('zone_traffic_received_' .. zone_name, zone['received'])/(params.pollInterval/1000), nil, src))
      end
    end
    for upstream_name, upstream_array in pairs(stats.upstreams) do
      if setContains(self.upstreams_to_check, upstream_name) then
        for _, upstream in pairs(upstream_array) do
          local backup = upstream['backup'] and ".b_" or "."
          local upstream_server_name = string.gsub(upstream_name, ":", "_") .. backup .. string.gsub(upstream['server'], ":", "_")
          local src = self.source .. '.' .. upstream_server_name
          local state = (string.upper(upstream['state']) == 'UP' and 0) or (string.upper(upstream['state']) == 'DRAINING' and 1) or (string.upper(upstream['state']) == 'DOWN' and 2) or (string.upper(upstream['state']) == 'UNAVAIL' and 3) or (string.upper(upstream['state']) == 'UNHEALTHY' and 4) or 5
          local health_check = upstream['health_checks']['last_passed'] and 1 or 0
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_STATE', state, nil, src))
          if params.upstream_state_event then
            local state_change = acc:accumulate('upstream_states_' .. upstream_server_name, state)

            if state_change ~= 0 then
              if string.upper(upstream['state']) == 'UP' then
                plugin:printInfo('Upstream State', self.source, src, string.format('Upstream server %s is now %s', upstream_server_name, upstream['state']))
              elseif string.upper(upstream['state']) == 'DRAINING' then
                plugin:printWarn('Upstream State', self.source, src, string.format('Upstream server %s is now %s', upstream_server_name, upstream['state']))
              elseif string.upper(upstream['state']) == 'DOWN' then
                plugin:printCritical('Upstream State', self.source, src, string.format('Upstream server %s is now %s', upstream_server_name, upstream['state']))
              elseif string.upper(upstream['state']) == 'UNAVAIL' then
                plugin:printError('Upstream State', self.source, src, string.format('Upstream server %s is now %s', upstream_server_name, upstream['state']))
              elseif string.upper(upstream['state']) == 'UNHEALTHY' then
                plugin:printWarn('Upstream State', self.source, src, string.format('Upstream server %s is now %s', upstream_server_name, upstream['state']))
              else
                plugin:printError('Upstream State', self.source, src, string.format('Upstream server %s is now %s', upstream_server_name, 'Unknown'))
              end
            end
          end
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_REQUESTS', acc:accumulate('upstream_requests_' .. upstream_name, upstream['requests'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_1XX_RESPONSES', acc:accumulate('upstream_1xx_responses_' .. upstream_server_name, upstream['responses']['1xx'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_2XX_RESPONSES', acc:accumulate('upstream_2xx_responses_' .. upstream_server_name, upstream['responses']['2xx'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_3XX_RESPONSES', acc:accumulate('upstream_3xx_responses_' .. upstream_server_name, upstream['responses']['3xx'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_4XX_RESPONSES', acc:accumulate('upstream_4xx_responses_' .. upstream_server_name, upstream['responses']['4xx'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_5XX_RESPONSES', acc:accumulate('upstream_5xx_responses_' .. upstream_server_name, upstream['responses']['5xx'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_TOTAL_RESPONSES', acc:accumulate('upstream_total_responses_' .. upstream_server_name, upstream['responses']['total'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_ACTIVE_CONNECTIONS', upstream['active'], nil, src))
          if upstream['max_conns'] and tonumber(upstream['max_conns']) > 0 then
            table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_PERC_USED_CONNECTIONS', tonumber(upstream['active'])/tonumber(upstream['max_conns']), nil, src))
          else
            table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_PERC_USED_CONNECTIONS', 0, nil, src))
          end
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_TRAFFIC_SENT', acc:accumulate('upstream_traffic_sent_' .. upstream_server_name, upstream['sent'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_TRAFFIC_RECEIVED', acc:accumulate('upstream_traffic_received_' .. upstream_server_name, upstream['received'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_FAILED_CHECKS', upstream['fails'], nil, src))
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_DOWNTIME', upstream['downtime'], nil, src))
          if upstream['health_checks']['checks'] and tonumber(upstream['health_checks']['checks']) > 0 then
            table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_PERC_FAILED', tonumber(upstream['health_checks']['fails'])/tonumber(upstream['health_checks']['checks']), nil, src))
          else
            table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_PERC_FAILED', 0, nil, src))
          end
          table.insert(metrics, pack('NGINX_PLUS_UPSTREAM_HEALTHY', health_check, nil, src))
          if params.upstream_failed_hc_event then
            local health_check_change = acc:accumulate('upstream_health_checks_' .. upstream_server_name, health_check)

            if health_check_change ~= 0 then
              if upstream['health_checks']['last_passed'] then
                plugin:printInfo('Upstream Health Check', self.source, src, string.format('Upstream server %s %s its last health check', upstream_server_name, 'passed'))
              else
                plugin:printWarn('Upstream Health Check', self.source, src, string.format('Upstream server %s %s its last health check', upstream_server_name, 'failed'))
              end
            end
          end
        end
      end
    end
    for TCP_zone_name, TCP_zone in pairs(stats.stream.server_zones) do
      if setContains(self.tcpzones_to_check, TCP_zone_name) then
        local src = self.source .. '.' .. string.gsub(TCP_zone_name, ":", "_")
        table.insert(metrics, pack('NGINX_PLUS_TCPZONE_CURRENT_CONNECTIONS', TCP_zone['processing'], nil, src))
        table.insert(metrics, pack('NGINX_PLUS_TCPZONE_CONNECTIONS', acc:accumulate('tcpzone_connections_' .. TCP_zone_name, TCP_zone['connections'])/(params.pollInterval/1000), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_TCPZONE_TRAFFIC_SENT', acc:accumulate('tcpzone_traffic_sent_' .. TCP_zone_name, TCP_zone['sent'])/(params.pollInterval/1000), nil, src))
        table.insert(metrics, pack('NGINX_PLUS_TCPZONE_TRAFFIC_RECEIVED', acc:accumulate('tcpzone_traffic_received_' .. TCP_zone_name, TCP_zone['received'])/(params.pollInterval/1000), nil, src))
      end
    end
    for TCP_upstream_name, TCP_upstream_array in pairs(stats.stream.upstreams) do
      if setContains(self.tcpupstreams_to_check, TCP_upstream_name) then
        for _, TCP_upstream in pairs(TCP_upstream_array) do
          local backup = TCP_upstream['backup'] and ".b_" or "."
          local TCP_upstream_server_name = string.gsub(TCP_upstream_name, ":", "_") .. backup .. string.gsub(TCP_upstream['server'], ":", "_")
          local src = self.source .. '.' .. TCP_upstream_server_name
          local state = (string.upper(TCP_upstream['state']) == 'UP' and 0) or (string.upper(TCP_upstream['state']) == 'DRAINING' and 1) or (string.upper(TCP_upstream['state']) == 'DOWN' and 2) or (string.upper(TCP_upstream['state']) == 'UNAVAIL' and 3) or (string.upper(TCP_upstream['state']) == 'UNHEALTHY' and 4) or 5
          local health_check = TCP_upstream['health_checks']['last_passed'] and 1 or 0
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_STATE', state, nil, src))
          if params.tcpup_state_event then
            local state_change = acc:accumulate('TCP_upstream_states_' .. TCP_upstream_server_name, state)

            if state_change ~= 0 then
              if string.upper(TCP_upstream['state']) == 'UP' then
                plugin:printInfo('TCP Upstream State', self.source, src, string.format('TCP upstream server %s is now %s', TCP_upstream_server_name, TCP_upstream['state']))
              elseif string.upper(TCP_upstream['state']) == 'DRAINING' then
                plugin:printWarn('TCP Upstream State', self.source, src, string.format('TCP upstream server %s is now %s', TCP_upstream_server_name, TCP_upstream['state']))
              elseif string.upper(TCP_upstream['state']) == 'DOWN' then
                plugin:printCritical('TCP Upstream State', self.source, src, string.format('TCP upstream server %s is now %s', TCP_upstream_server_name, TCP_upstream['state']))
              elseif string.upper(TCP_upstream['state']) == 'UNAVAIL' then
                plugin:printError('TCP Upstream State', self.source, src, string.format('TCP upstream server %s is now %s', TCP_upstream_server_name, TCP_upstream['state']))
              elseif string.upper(TCP_upstream['state']) == 'UNHEALTHY' then
                plugin:printError('TCP Upstream State', self.source, src, string.format('TCP upstream server %s is now %s', TCP_upstream_server_name, TCP_upstream['state']))
              else
                plugin:printError('TCP Upstream State', self.source, src, string.format('TCP upstream server %s is now %s', TCP_upstream_server_name, 'Unknown'))
              end
            end
          end
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_CONNECTIONS', acc:accumulate('tcpup_connections_' .. TCP_upstream_server_name, TCP_upstream['connections'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_ACTIVE_CONNECTIONS', TCP_upstream['active'], nil, src))
          if TCP_upstream['max_conns'] and tonumber(TCP_upstream['max_conns']) > 0 then
            table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_PERC_USED_CONNECTIONS', tonumber(TCP_upstream['active'])/tonumber(TCP_upstream['max_conns'])/(params.pollInterval/1000), nil, src))
          else
            table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_PERC_USED_CONNECTIONS', 0, nil, src))
          end
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_TRAFFIC_SENT', acc:accumulate('tcpup_traffic_sent_' .. TCP_upstream_server_name, TCP_upstream['sent'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_TRAFFIC_RECEIVED', acc:accumulate('tcpup_traffic_received_' .. TCP_upstream_server_name, TCP_upstream['received'])/(params.pollInterval/1000), nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_FAILED_CHECKS', TCP_upstream['fails'], nil, src))
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_DOWNTIME', TCP_upstream['downtime'], nil, src))
          if TCP_upstream['health_checks']['checks'] and tonumber(TCP_upstream['health_checks']['checks']) > 0 then
            table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_PERC_FAILED', tonumber(TCP_upstream['health_checks']['fails'])/tonumber(TCP_upstream['health_checks']['checks'])/(params.pollInterval/1000), nil, src))
          else
            table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_PERC_FAILED', 0, nil, src))
          end
          table.insert(metrics, pack('NGINX_PLUS_TCPUPSTREAM_HEALTHY', health_check, nil, src))
          if params.tcpup_failed_hc_event then
            local health_check_change = acc:accumulate('TCP_upstream_health_checks_' .. TCP_upstream_server_name, health_check)

            if health_check_change ~= 0 then
              if TCP_upstream['health_checks']['last_passed'] then
                plugin:printInfo('TCP Upstream Health Check', self.source, src, string.format('TCP upstream server %s %s its last health check', TCP_upstream_server_name, 'passed'))
              else
                plugin:printWarn('TCP Upstream Health Check', self.source, src, string.format('TCP upstream server %s %s its last health check', TCP_upstream_server_name, 'failed'))
              end
            end
          end
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
