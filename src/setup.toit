// Copyright (C) 2023 Kasper Lund.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import log
import monitor

import encoding.url

import net
import net.tcp
import net.udp
import net.wifi

import http
import dns_simple_server as dns

import encoding.json
import system.assets

import .mode as mode

ASSETS ::= assets.decode

DEFAULT_SSID_     ::= "mywifi"
DEFAULT_PASSWORD_ ::= "12345678"

TEMPORARY_REDIRECTS ::= {
  "generate_204": "/",    // Used by Android captive portal detection.
  "gen_204": "/",         // Used by Android captive portal detection.
}

DEFAULT_INDEX ::= """
<html>
  <head>
    <title>WiFi settings</title>
{{css-link}}  </head>
  <body>
    <h1>Update WiFi settings</h1>
    <form>
      <label for="ssid">SSID:</label><br>
      <input type="text" id="ssid" name="ssid" autocorrect="off" autocapitalize="none"><br>
      <label for="password">Password:</label><br>
      <input type="text" id="password" name="password" autocorrect="off" autocapitalize="none"><br>
      <br>
      <input type="submit" value="Update">
    </form>
    <p>
    {{access-points}}
  </body>
</html>
"""

main:
  run_captive_portal_setup

/**
Runs the captive portal WiFi setup.

Creates a WiFi access point with the given $ssid and $password,
  serves a captive portal for WiFi credential configuration, and
  reboots into application mode when done.
*/
run_captive_portal_setup --ssid/string=DEFAULT_SSID_ --password/string=DEFAULT_PASSWORD_:
  // We allow the setup container to start and eagerly terminate
  // if we don't need it yet. This makes it possible to have
  // the setup container installed always, but have it run with
  // the -D jag.disabled flag in development.
  if mode.RUNNING: return

  // Devices that were never configured should stay in setup mode
  // until credentials are entered successfully. Devices that used
  // to have WiFi credentials still time out so the main application
  // can continue its retry loop.
  timeout/Duration? := null
  if mode.has_wifi_configuration:
    // When running in development we run for less time before we
    // back to trying out the app. This makes it faster to correct
    // things and retry, but it does mean that you have less time
    // to connect to the established WiFi.
    timeout = mode.DEVELOPMENT ? (Duration --s=30) : (Duration --m=3)
  catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR): run_ timeout --ssid=ssid --password=password

  // We're done trying to complete the setup. Go back to running
  // the application and let it choose when to re-initiate the
  // setup process.
  mode.run_application

run_ timeout/Duration? --ssid/string --password/string:
  log.info "scanning for wifi access points"
  channels := ByteArray 12: it + 1
  access_points/List := []
  scan-exception := catch:
    access_points = wifi.scan channels
    access_points.sort --in_place: | a b | b.rssi.compare_to a.rssi
  if scan-exception:
    log.warn "wifi access point scan failed; continuing without scan results"

  log.info "establishing wifi in AP mode ($ssid)"
  while true:
    network_ap := wifi.establish
        --ssid=ssid
        --password=password
    credentials/Map? := null
    try:
      if timeout:
        with_timeout timeout: credentials = run_captive_portal_ network_ap access_points
      else:
        credentials = run_captive_portal_ network_ap access_points
    finally:
      network_ap.close

    if credentials:
      exception := catch:
        log.info "connecting to wifi in STA mode" --tags=credentials
        network_sta := wifi.open
            --save
            --ssid=credentials["ssid"]
            --password=credentials["password"]
        network_sta.close
        mode.mark_wifi_configured
        log.info "connecting to wifi in STA mode => success" --tags=credentials
        return
      log.warn "connecting to wifi in STA mode => failed" --tags=credentials

run_captive_portal_ network/net.Interface access_points/List -> Map:
  results := Task.group --required=1 [
    :: run_dns_ network,
    :: run_http network access_points,
  ]
  return results[1]  // Return the result from the HTTP server at index 1.

run_dns_ network/net.Interface -> none:
  device_ip_address := network.address
  socket := network.udp_open --port=53
  hosts := dns.SimpleDnsServer device_ip_address  // Answer the device IP to all queries.

  try:
    while not Task.current.is_canceled:
      datagram/udp.Datagram := socket.receive
      response := hosts.lookup datagram.data
      if not response: continue
      socket.send (udp.Datagram response datagram.address)
  finally:
    socket.close

/**
Runs the captive-portal HTTP server on $network and returns the
  WiFi credentials submitted by the user.

Listens on the given $port (defaults to 80) and serves either the
  bundled $DEFAULT_INDEX or the assets injected via `system.assets`.
  The server keeps running until a successful credential submission
  arrives, at which point the listening socket is closed and the
  submitted credentials are returned.

Exposed primarily so tests and advanced callers can drive the HTTP
  layer without bringing up an actual WiFi access point.
*/
run_http network/net.Interface access_points/List --port/int=80 -> Map:
  socket := network.tcp_listen port
  server := http.Server --max-tasks=4
  result/Map? := null
  try:
    server.listen socket:: | request writer |
      result = handle_http_request_ request writer access_points
      if result: socket.close
  finally:
    if result: return result
    socket.close
  unreachable

handle_http_request_ request/http.Request writer/http.ResponseWriter access_points/List -> Map?:
  query := url.QueryString.parse request.path
  resource := query.resource
  if resource == "/": resource = "index.html"
  if resource == "/hotspot-detect.html": resource = "index.html"  // Needed for iPhones.
  if resource.starts_with "/": resource = resource[1..]

  TEMPORARY_REDIRECTS.get resource --if_present=:
    writer.headers.set "Location" it
    writer.write_headers 302
    return null

  if resource == "access-points.json":
    writer.headers.set "Content-Type" "application/json"
    writer.write (json.encode (access_points.map: { "ssid": it.ssid, "rssi": it.rssi }))
    return null

  asset := ASSETS.get resource
  if asset:
    if resource.ends_with ".html":
      writer.headers.set "Content-Type" "text/html"
    else if resource.ends_with ".css":
      writer.headers.set "Content-Type" "text/css"
    else if resource.ends_with ".js":
      writer.headers.set "Content-Type" "application/javascript"
    else:
      writer.headers.set "Content-Type" "application/octet-stream"

    if resource == "index.html":
      substitutions := {
        "access-points": (access_points.map: "$it.ssid<br>").join "\n"
      }
      str := asset.to_string
      writer.write (str.substitute: substitutions.get it --if_absent=(: "{{$it}}"))
    else:
      writer.write asset
      // Static assets are not credential submissions; we are done.
      return null
  else if resource != "index.html":
    writer.headers.set "Content-Type" "text/plain"
    writer.write_headers 404
    writer.write "Not found: $resource"
    return null
  else:
    substitutions := {
      "access-points": (access_points.map: "$it.ssid<br>").join "\n",
      "css-link": (ASSETS.contains "style.css") ? "<link rel=\"stylesheet\" href=\"style.css\">\n" : "",
    }
    writer.headers.set "Content-Type" "text/html"
    writer.write (DEFAULT_INDEX.substitute: substitutions.get it --if_absent=(: "{{$it}}"))

  if query.parameters.is_empty: return null
  ssid := query.parameters.get "ssid"
  password := query.parameters.get "password"
  if ssid and password:
    return { "ssid": ssid.trim, "password": password.trim }
  return null
