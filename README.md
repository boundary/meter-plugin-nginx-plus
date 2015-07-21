# Boundary Nginx Plus Plugin

A Boundary plugin that collects metrics from an Nginx Plus instance. This plugin is not intended for the Nginx F/OSS edition as fewer metrics are available there.

### Prerequisites

#### Supported OS

|     OS    | Linux | Windows | SmartOS | OS X |
|:----------|:-----:|:-------:|:-------:|:----:|
| Supported |   v   |    v    |    v    |  v   |

#### Boundary Meter versions v4.2 or later 

- To install new meter go to Settings->Installation or [see instructions](https://help.boundary.com/hc/en-us/sections/200634331-Installation). 
- To upgrade the meter to the latest version - [see instructions](https://help.boundary.com/hc/en-us/articles/201573102-Upgrading-the-Boundary-Meter).

### Plugin Setup

To enable collecting metrics per virtual server, you need to enable zones. See Nginx documentation for more details about [status_zone](http://nginx.org/en/docs/http/ngx_http_status_module.html#status_zone) directive. Several virtual servers may share the same zone.

    ```
    status_zone <your-zone-goes-here>;
    ```

Once you make the update, reload your nginx configuration:
    ```bash
     $ sudo service nginx reload
    ```

#### Verify `HttpStatusModule` is Collecting Statistics

Run the following command, which shows the expected output:
    ```bash
    $ curl http://localhost:8000/status
    {JSON Output here}
    ```
You can see an example of the output [here](http://demo.nginx.com/status)

### Plugin Configuration Fields

|Field Name                |Description                                                                                           |
|:-------------------------|:-----------------------------------------------------------------------------------------------------|
|Source                    |The Source to display in the legend for the nginx data.  It will default to the hostname of the server|
|Statistics URL            |The URL endpoint of where the nginx statistics are hosted.                                            |
|Strict SSL                |Use Strict SSL checking when HTTPS is enabled, enabled by default                                     |
|Username                  |If the endpoint is password protected, what username should graphdat use when calling it.             |
|Password                  |If the endpoint is password protected, what password should graphdat use when calling it.             |
|Cache Filter              |Which Caches Should be Viewed (blank/missing means all)                                               |
|Zone Filter               |Which Zones Should be Viewed (blank/missing means all)                                                |
|TCP Zone Filter           |Which TCP Zones Should be Viewed (blank/missing means all)                                            |
|Upstream Server Filter    |Which Upstream Servers Should be Viewed (blank/missing means all)                                     |
|TCP Upstream Server Filter|Which TCP Upstream Servers Should be Viewed (blank/missing means all)                                 |


### Metrics Collected

|Metric Name                  |Description                                                                                   |
|:----------------------------|:---------------------------------------------------------------------------------------------|
|Nginx Active Connections     |Active connections to nginx                                                                   |
|Nginx Uptime                 |Amount of time the Nginx server has been handling requests                                    |
|Nginx Waiting                |Keep-alive connections with Nginx in a wait state                                             |
|Nginx Connections Handled    |Connections handled by nginx                                                                  |
|Nginx Connections Not Handled|Connections accepted, but not handled                                                         |
|Nginx Current Requests       |Current requests to nginx                                                                     |
|Nginx Requests               |Requests per second to nginx                                                                  |
|Nginx Requests per Connection|Requests per handled connections for nginx                                                    |
|Nginx Responses              |The total number of responses sent to clients                                                 |
|Nginx Cache Heat             |Whether the current cache is warm or cold                                                     |
|Nginx Cache Size             |The cache size change per second                                                              |
|Nginx Cache Used             |The percent of the cache currently in use                                                     |
|Nginx Cache Served           |The total number of bytes served from the cache                                               |
|Nginx Cache Written          |The total number of bytes written to the cache                                                |
|Nginx Cache Bypassed         |The total number of bytes read from the proxied server                                        |
|Nginx Cache Hit Percentage   |The percentage that the cache was used to handle requests                                     |
|Nginx Zone Requests          |The number of requests per second being handled in the zone                                   |
|Nginx Zone Current Requests  |The total number of active requests in the zone                                               |
|Nginx Zone 1XX Responses     |The number of 1XX responses per second being sent from the zone                               |
|Nginx Zone 2XX Responses     |The number of 2XX responses per second being sent from the zone                               |
|Nginx Zone 3XX Responses     |The number of 3XX responses per second being sent from the zone                               |
|Nginx Zone 4XX Responses     |The number of 4XX responses per second being sent from the zone                               |
|Nginx Zone 5XX Responses     |The number of 5XX responses per second being sent from the zone                               |
|Nginx Zone Total Responses   |The total number of responses per second being sent from the zone                             |
|Nginx Zone Traffic Sent      |The total number of bytes sent to the zone                                                    |
|Nginx Zone Traffic Received  |The total number of bytes received from the zone                                              |
|Nginx Upstream Server State  |The current state of the upstream server (0=up, 1=draining, 2=down, 3=unavail, 4=unhealthy)   |
|Nginx Upstream 1XX Responses |The number of 1XX responses per second being sent from the upstream server                    |
|Nginx Upstream 2XX Responses |The number of 2XX responses per second being sent from the upstream server                    |
|Nginx Upstream 3XX Responses |The number of 3XX responses per second being sent from the upstream server                    |
|Nginx Upstream 4XX Responses |The number of 4XX responses per second being sent from the upstream server                    |
|Nginx Upstream 5XX Responses |The number of 5XX responses per second being sent from the upstream server                    |
|Nginx Upstream Total Response|The total number of responses per second being sent from the upstream server                  |
|Nginx Upstream Active Conns  |The total number of active connections to the upstream server                                 |
|Nginx Upstream %Used  Conns  |The percent of the connections currently in use to the upstream server                        |
|Nginx Upstream Traffic Sent  |The total number of bytes sent to the upstream server                                         |
|Nginx Upstream Traffic Receiv|The total number of bytes received from the upstream server                                   |
|Nginx Upstream Failed Checks |The number of failed server checks to the upstream server                                     |
|Nginx Upstream Downtime      |The amount of time the upstream server has been down                                          |
|Nginx Upstream % Failed      |The percent of failed health checks of the upstream server                                    |
|Nginx Upstream Last Health   |The value of the last health check of the upstream server (0=healthy, 1=unhealthy)            |
|Nginx TCP Zone Cur Connection|The total number of active connections in the TCP Zone                                        |
|Nginx TCP Zone Connections   |The connections per second in the TCP Zone                                                    |
|Nginx TCP Zone Traffic Sent  |The total number of bytes sent to the TCP zone                                                |
|Nginx TCP Zone Traffic Receiv|The total number of bytes received from the TCP zone                                          |
|Nginx TCP Upstream Srv State |The current state of the TCP upstream server (0=up,1=draining,2=down,3=unavail,4=unhealthy)   |
|Nginx TCP Upstream Active Con|The total number of active connections to the TCP upstream server                             |
|Nginx TCP Upstream %Used  Con|The percent of the connections currently in use to the TCP upstream server                    |
|Nginx TCP Upstream Traff Sent|The total number of bytes sent to the TCP upstream server                                     |
|Nginx TCP Upstream Traff Rec |The total number of bytes received from the TCP upstream server                               |
|Nginx TCP Upstream Failed Chk|The number of failed server checks to the TCP upstream server                                 |
|Nginx TCP Upstream Downtime  |The amount of time the TCP upstream server has been down                                      |
|Nginx TCP Upstream % Failed  |The percent of failed health checks of the TCP upstream server                                |
|Nginx TCP Upstream Last Healt|The value of the last health check of the TCP upstream server (0=healthy, 1=unhealthy)        |
|Nginx TCP Upstream Conn Time |The average time to connect to the TCP upstream serverwn                                      |
|Nginx TCP Upstream 1Byte Time|The average time to receive the first byte of data from the TCP upstream server               |
|Nginx TCP Upstream Resp Time |The average time to receive the last byte of data from the TCP upstream server                |

### Dashboards

- Nginx Plus Summary
- Nginx Plus Zones
- Nginx Plus Upstreams
- Nginx Plus TCP Zones
- Nginx Plus TCP Upstreams
- Nginx Plus Caches

### References

http://nginx.org/en/docs/http/ngx_http_status_module.html
