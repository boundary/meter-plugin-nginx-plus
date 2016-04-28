-- Copyright 2015 Boundary, Inc.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--    http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local framework = require('framework')
local url = require('url')
local Plugin  = framework.Plugin
local WebRequestDataSource = framework.WebRequestDataSource
local Accumulator = framework.Accumulator
local auth = framework.util.auth
local ipack = framework.util.ipack
local toSet = framework.table.toSet
local parseJson = framework.util.parseJson
local ratio = framework.util.ratio

local params = framework.params or {}

local function setContains(set, key)
  --if set then
   -- return set[key] ~= nil
  --else
   -- return true
  --end
  if count(set) == 0 then
     return true
  end
   if set then
    return set[key] ~= nil
  else
    return true
  end
end

local state_to_event_map = {
  up = 'info',
  draining = 'warn',
  down = 'critical',
  unavail = 'error',
  unhealthy = 'warn'
}

local options = url.parse(params.url)
options.auth = auth(params.username, params.password) 
options.wait_for_end = true
local ds = WebRequestDataSource:new(options)
local _acc = Accumulator:new()
local function acc(key, value)
  return _acc:accumulate(key, value)
end

local plugin = Plugin:new(params, ds)
plugin.caches_to_check = toSet(params.caches or {})
plugin.zones_to_check = toSet(params.zones or {})
plugin.tcpzones_to_check = toSet(params.tcpzones or {})
plugin.upstreams_to_check = toSet(params.upstreams or {})
plugin.tcpupstreams_to_check = toSet(params.tcpupstreams or {})

local last_uptime = nil

function plugin:onParseValues(data)
  local metrics = {}
  local metric = function (...)
    ipack(metrics, ...)
  end

  local success, stats = parseJson(data)
  if not success then do return end end

  local handled = stats['connections']['accepted'] - stats['connections']['dropped']
  local requests = stats['requests']['total']
  local reqs_per_connection = ratio(requests, handled)

  metrics['NGINX_PLUS_ACTIVE_CONNECTIONS'] = stats['connections']['active'] + stats['connections']['idle']
  metrics['NGINX_PLUS_WAITING'] = stats['connections']['idle']
  metrics['NGINX_PLUS_HANDLED'] = acc('handled', handled)/(params.pollInterval/1000)
  metrics['NGINX_PLUS_NOT_HANDLED'] = stats['connections']['dropped']
  metrics['NGINX_PLUS_REQUESTS'] = acc('requests', requests)/(params.pollInterval/1000)
  metrics['NGINX_PLUS_CURRENT_REQUESTS'] = stats['requests']['current']
  metrics['NGINX_PLUS_REQUESTS_PER_CONNECTION'] = reqs_per_connection
  local current_uptime = stats['timestamp'] - stats['load_timestamp']
  if last_uptime and current_uptime < last_uptime then
    self:emitEvent('warn', 'Server uptime changed!', self.source, self.source)
  end
  last_uptime = current_uptime 

  -- Caches metrics
  --print("Cache Block Sstart here---------------------------")
  for cache_name, cache in pairs(stats.caches) do
    
    local listOfCacheZones = {}
      local cacheZones = ""
      for _,v in pairs(params.caches) do
            cacheZones = v
      end
      if isBlank(cacheZones) then
       --empty
      else
          local listOfCacheZoneArrays = cacheZones:split(",")
          for i = 1, #listOfCacheZoneArrays do
             listOfCacheZones[listOfCacheZoneArrays[i]] = listOfCacheZoneArrays[i]
          end
      end
    if setContains(listOfCacheZones, cache_name) then
      local src = self.source .. '.' .. string.gsub(cache_name, ":", "_")
      local served = cache['hit']['bytes'] + cache['stale']['bytes'] + cache['updating']['bytes'] + cache['revalidated']['bytes']
      local bypassed = cache['miss']['bytes'] + cache['expired']['bytes'] + cache['bypass']['bytes']

      metric('NGINX_PLUS_CACHE_COLD', cache['cold'] and 1 or 0, nil, src)

      -- Cache cold change event
      if params.cache_cold_event then
        local cold_change = acc('caches_cold_' .. cache_name, cache['cold'] and 1 or 0)
        if cold_change ~= 0 then
          local cold = cache['cold'] and 'Cold' or 'Warm'
          local eventType = cache['cold'] and 'warn' or 'info'
          self:emitEvent(eventType, cache_name .. (' Cache %s'):format(cold), src, self.source, string.format('Cache %s is now %s|h:%s|s:%s', cache_name, cold))
        end
      end
      metric('NGINX_PLUS_CACHE_SIZE', cache['size'], nil, src)
      metric('NGINX_PLUS_CACHE_USED', ratio(cache['size'], cache['max_size']), nil, src)
      metric('NGINX_PLUS_CACHE_SERVED', served, nil, src)
      metric('NGINX_PLUS_CACHE_WRITTEN', cache['miss']['bytes_written'] + cache['expired']['bytes_written'] + cache['bypass']['bytes_written'], nil, src)
      metric('NGINX_PLUS_CACHE_BYPASSED', bypassed, nil, src)
      metric('NGINX_PLUS_CACHE_HIT_PERCENT', ratio(served, served+bypassed), nil, src)
    end
  end
 --print("Cache Block END here---------------------------")

 --print("Server zone Block Sstart here---------------------------")

  -- Server Zones metrics
  for zone_name, zone in pairs(stats.server_zones) do
      local listOfZones = {}
      local zones = ""
      for _,v in pairs(params.zones) do
            zones = v
      end
     if isBlank(zones) then
       --empty 
     else
        local sepratedZonesArray = zones:split(",")
        for i = 1, #sepratedZonesArray do
               listOfZones[sepratedZonesArray[i]] = sepratedZonesArray[i]
        end
     end
    if setContains(listOfZones, zone_name) then
      local src = self.source .. '.' .. string.gsub(zone_name, ":", "_")
      metric('NGINX_PLUS_ZONE_CURRENT_REQUESTS', zone['processing'], nil, src)
      metric('NGINX_PLUS_ZONE_REQUESTS', acc('zone_requests_' .. zone_name, zone['requests'])/(params.pollInterval/1000), nil, src)
      metric('NGINX_PLUS_ZONE_1XX_RESPONSES', acc('zone_1xx_responses_' .. zone_name, zone['responses']['1xx'])/(params.pollInterval/1000), nil, src)
      metric('NGINX_PLUS_ZONE_2XX_RESPONSES', acc('zone_2xx_responses_' .. zone_name, zone['responses']['2xx'])/(params.pollInterval/1000), nil, src)
      metric('NGINX_PLUS_ZONE_3XX_RESPONSES', acc('zone_3xx_responses_' .. zone_name, zone['responses']['3xx'])/(params.pollInterval/1000), nil, src)
      metric('NGINX_PLUS_ZONE_4XX_RESPONSES', acc('zone_4xx_responses_' .. zone_name, zone['responses']['4xx'])/(params.pollInterval/1000), nil, src)
      metric('NGINX_PLUS_ZONE_5XX_RESPONSES', acc('zone_5xx_responses_' .. zone_name, zone['responses']['5xx'])/(params.pollInterval/1000), nil, src)
      metric('NGINX_PLUS_ZONE_TOTAL_RESPONSES', acc('zone_total_responses_' .. zone_name, zone['responses']['total'])/(params.pollInterval/1000), nil, src)
      metric('NGINX_PLUS_ZONE_TRAFFIC_SENT', acc('zone_traffic_sent_' .. zone_name, zone['sent'])/(params.pollInterval/1000), nil, src)
      metric('NGINX_PLUS_ZONE_TRAFFIC_RECEIVED', acc('zone_traffic_received_' .. zone_name, zone['received'])/(params.pollInterval/1000), nil, src)
    end
  end

--print("Server zone Block END  here---------------------------")

  -- Upstreams metrics
  for upstream_name, upstream_array in pairs(stats.upstreams) do
    if setContains(self.upstreams_to_check, upstream_name) then
      for _, upstream in pairs(upstream_array) do
        local backup = upstream['backup'] and ".b_" or "."
        local upstream_server_name = string.gsub(upstream_name, ":", "_") .. backup .. string.gsub(upstream['server'], ":", "_")
        local src = self.source .. '.' .. upstream_server_name

        local state = (upstream['state'] == 'up' and 0) or (upstream['state'] == 'draining' and 1) or (upstream['state'] == 'down' and 2) or (upstream['state'] == 'unavail' and 3) or (upstream['state'] == 'unhealthy' and 4) or 5
        local health_check = upstream['health_checks']['last_passed'] and 1 or 0
        metric('NGINX_PLUS_UPSTREAM_STATE', state, nil, src)

        -- Upstream state change event
        if params.upstream_state_event then
          local state_change = acc('upstream_states_' .. upstream_server_name, state)
          if state_change ~= 0 then
            local eventType = state_to_event_map[upstream['state']] or 'error'
            self:emitEvent(eventType, 'Upstream ' .. upstream_server_name .. ' ' .. upstream['state'], src, self.source, string.format('Upstream server %s is now %s', upstream_server_name, upstream['state']))
          end
        end
        metric('NGINX_PLUS_UPSTREAM_REQUESTS', acc('upstream_requests_' .. upstream_name, upstream['requests'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_UPSTREAM_1XX_RESPONSES', acc('upstream_1xx_responses_' .. upstream_server_name, upstream['responses']['1xx'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_UPSTREAM_2XX_RESPONSES', acc('upstream_2xx_responses_' .. upstream_server_name, upstream['responses']['2xx'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_UPSTREAM_3XX_RESPONSES', acc('upstream_3xx_responses_' .. upstream_server_name, upstream['responses']['3xx'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_UPSTREAM_4XX_RESPONSES', acc('upstream_4xx_responses_' .. upstream_server_name, upstream['responses']['4xx'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_UPSTREAM_5XX_RESPONSES', acc('upstream_5xx_responses_' .. upstream_server_name, upstream['responses']['5xx'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_UPSTREAM_TOTAL_RESPONSES', acc('upstream_total_responses_' .. upstream_server_name, upstream['responses']['total'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_UPSTREAM_ACTIVE_CONNECTIONS', upstream['active'], nil, src)
        metric('NGINX_PLUS_UPSTREAM_PERC_USED_CONNECTIONS', ratio(upstream['active'], upstream['max_conns']), nil, src)
        metric('NGINX_PLUS_UPSTREAM_TRAFFIC_SENT', acc('upstream_traffic_sent_' .. upstream_server_name, upstream['sent'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_UPSTREAM_TRAFFIC_RECEIVED', acc('upstream_traffic_received_' .. upstream_server_name, upstream['received'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_UPSTREAM_FAILED_CHECKS', upstream['fails'], nil, src)
        metric('NGINX_PLUS_UPSTREAM_DOWNTIME', upstream['downtime'], nil, src)
        metric('NGINX_PLUS_UPSTREAM_PERC_FAILED', ratio(upstream['health_checks']['fails']/upstream['health_checks']['checks']), nil, src)
        metric('NGINX_PLUS_UPSTREAM_HEALTHY', health_check, nil, src)

        -- Upstream failed health check event
        if params.upstream_failed_hc_event then
          local health_check_change = acc('upstream_health_checks_' .. upstream_server_name, health_check)
          if health_check_change ~= 0 then
            local passed =  upstream['health_checks']['last_passed'] and 'passed' or 'failed'
            local eventType = upstream['health_checks']['last_passed'] and 'info' or 'warn'
            self:emitEvent(eventType, 'Upstream ' .. upstream_server_name .. (' Health Check %s'):format(passed), src, self.source, ('Upstream server %s %s its last health check'):format(upstream_server_name, passed))
          end
        end
      end
    end
  end

  -- TCP Zones
  for TCP_zone_name, TCP_zone in pairs(stats.stream.server_zones) do
    if setContains(self.tcpzones_to_check, TCP_zone_name) then
      local src = self.source .. '.' .. string.gsub(TCP_zone_name, ":", "_")
      metric('NGINX_PLUS_TCPZONE_CURRENT_CONNECTIONS', TCP_zone['processing'], nil, src)
      metric('NGINX_PLUS_TCPZONE_CONNECTIONS', acc('tcpzone_connections_' .. TCP_zone_name, TCP_zone['connections'])/(params.pollInterval/1000), nil, src)
      metric('NGINX_PLUS_TCPZONE_TRAFFIC_SENT', acc('tcpzone_traffic_sent_' .. TCP_zone_name, TCP_zone['sent'])/(params.pollInterval/1000), nil, src)
      metric('NGINX_PLUS_TCPZONE_TRAFFIC_RECEIVED', acc('tcpzone_traffic_received_' .. TCP_zone_name, TCP_zone['received'])/(params.pollInterval/1000), nil, src)
    end
  end

  -- TCP Upstream
  for TCP_upstream_name, TCP_upstream_array in pairs(stats.stream.upstreams) do
    if setContains(self.tcpupstreams_to_check, TCP_upstream_name) then
      for _, TCP_upstream in pairs(TCP_upstream_array) do
        local backup = TCP_upstream['backup'] and ".b_" or "."
        local TCP_upstream_server_name = string.gsub(TCP_upstream_name, ":", "_") .. backup .. string.gsub(TCP_upstream['server'], ":", "_")
        local src = self.source .. '.' .. TCP_upstream_server_name
        local state = (string.upper(TCP_upstream['state']) == 'UP' and 0) or (string.upper(TCP_upstream['state']) == 'DRAINING' and 1) or (string.upper(TCP_upstream['state']) == 'DOWN' and 2) or (string.upper(TCP_upstream['state']) == 'UNAVAIL' and 3) or (string.upper(TCP_upstream['state']) == 'UNHEALTHY' and 4) or 5
        local health_check = TCP_upstream['health_checks']['last_passed'] and 1 or 0
        metric('NGINX_PLUS_TCPUPSTREAM_STATE', state, nil, src)

        -- tcpup_state_event
        if params.tcpup_state_event then
          local state_change = acc('TCP_upstream_states_' .. TCP_upstream_server_name, state)
          if state_change ~= 0 then
            local eventType = state_to_event_map[TCP_upstream['state']] or 'error'
            self:emitEvent(eventType, 'TCP Upstream ' .. TCP_upstream_server_name .. ' ' .. TCP_upstream['state'], src, self.source, string.format('TCP upstream server %s is now %s', TCP_upstream_server_name, TCP_upstream['state']))
          end
        end
        metric('NGINX_PLUS_TCPUPSTREAM_CONNECTIONS', acc('tcpup_connections_' .. TCP_upstream_server_name, TCP_upstream['connections'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_TCPUPSTREAM_ACTIVE_CONNECTIONS', TCP_upstream['active'], nil, src)
        metric('NGINX_PLUS_TCPUPSTREAM_PERC_USED_CONNECTIONS', ratio(TCP_upstream['active'], TCP_upstream['max_conns'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_TCPUPSTREAM_TRAFFIC_SENT', acc('tcpup_traffic_sent_' .. TCP_upstream_server_name, TCP_upstream['sent'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_TCPUPSTREAM_TRAFFIC_RECEIVED', acc('tcpup_traffic_received_' .. TCP_upstream_server_name, TCP_upstream['received'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_TCPUPSTREAM_FAILED_CHECKS', TCP_upstream['fails'], nil, src)
        metric('NGINX_PLUS_TCPUPSTREAM_DOWNTIME', TCP_upstream['downtime'], nil, src)
        metric('NGINX_PLUS_TCPUPSTREAM_PERC_FAILED', ratio(TCP_upstream['health_checks']['fails'], TCP_upstream['health_checks']['checks'])/(params.pollInterval/1000), nil, src)
        metric('NGINX_PLUS_TCPUPSTREAM_HEALTHY', health_check, nil, src)

        -- tcpuup_failed_hc_event
        if params.tcpup_failed_hc_event then
          local health_check_change = acc('TCP_upstream_health_checks_' .. TCP_upstream_server_name, health_check)
          if health_check_change ~= 0 then
            local passed = TCP_upstream['health_checks']['last_passed'] and 'passed' or 'failed' 
            local eventType = TCP_upstream['health_checks']['last_passed'] and 'info' or 'warn' 
            self:emitEvent(eventType, 'TCP Upstream ' .. TCP_upstream_server_name .. (' Health Check %s'):format(passed), src, self.source, string.format('TCP upstream server %s %s its last health check', TCP_upstream_server_name, passed))
          end
        end
        metric('NGINX_PLUS_TCPUPSTREAM_CONNECT_TIME', TCP_upstream['connect_time'], nil, src)
        metric('NGINX_PLUS_TCPUPSTREAM_FIRST_BYTE_TIME', TCP_upstream['first_byte_time'], nil, src)
        metric('NGINX_PLUS_TCPUPSTREAM_RESPONSE_TIME', TCP_upstream['response_time'], nil, src)
      end
    end
  end

  return metrics 
end
--count number of elements  found in array
function count( tbl )
  local count = 0
  for _ in pairs( tbl ) do
    count = count + 1
    end
  return count
end
--checking given string is empty
function isBlank(x)
  return not not tostring(x):find("^%s*$")
end
--Split string by comma
function string:split( inSplitPattern, outResults )
  if not outResults then
    outResults = { }
  end
  local theStart = 1
  local theSplitStart, theSplitEnd = string.find( self, inSplitPattern, theStart )
  while theSplitStart do
    table.insert( outResults, string.sub( self, theStart, theSplitStart-1 ) )
    theStart = theSplitEnd + 1
    theSplitStart, theSplitEnd = string.find( self, inSplitPattern, theStart )
  end
  table.insert( outResults, string.sub( self, theStart ) )
  return outResults
end
 
plugin:run()

