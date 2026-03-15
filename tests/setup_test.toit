import expect show *
import net
import http
import monitor
import io

import ..src.setup as setup

class MockAccessPoint:
  ssid/string
  rssi/int
  constructor .ssid .rssi:

main:
  print "Running setup test..."
  network := net.open
  access_points := [
    MockAccessPoint "MyNetwork" -50,
    MockAccessPoint "OtherNetwork" -70
  ]
  
  // Start the HTTP server in a separate task.
  server_task := task::
    setup.run_http network access_points --port=8080
    
  print "Server started"
  
  // Wait a bit for the server to listen
  sleep --ms=500
  
  // Create an HTTP client
  client := http.Client network
  response := client.get --host="127.0.0.1" --port=8080 --path="/"
  
  bytes := #[]
  while data := response.body.read:
    bytes += data
  str := bytes.to_string
  
  print "Response status: $response.status_code"
  print "Response body:"
  print str
  
  expect_equals 200 response.status_code
  expect_equals true (str.contains "Update WiFi settings")
  expect_equals true (str.contains "MyNetwork")
  
  client.close
  network.close
  
  server_task.cancel
  print "Test passed!"
