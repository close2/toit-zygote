// Copyright (C) 2023 Kasper Lund.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import esp32
import system.firmware
import system.storage
import system.containers

DEVELOPMENT/bool ::= containers.images.any: it.name == "jaguar"
RUNNING/bool ::= (ZYGOTE_STORE_.get ZYGOTE_STATE_KEY_) != ZYGOTE_STATE_SETUP_

run_application -> none:
  ZYGOTE_STORE_.remove ZYGOTE_STATE_KEY_
  esp32.deep_sleep (Duration --ms=10)

run_setup -> none:
  ZYGOTE_STORE_[ZYGOTE_STATE_KEY_] = ZYGOTE_STATE_SETUP_
  esp32.deep_sleep (Duration --ms=10)

has_wifi_configuration -> bool:
  if has_firmware_wifi_configuration_: return true
  return ZYGOTE_STORE_.get ZYGOTE_WIFI_CONFIGURED_KEY_ --if-absent=(: false)

mark_wifi_configured -> none:
  ZYGOTE_STORE_[ZYGOTE_WIFI_CONFIGURED_KEY_] = true

clear_wifi_configured -> none:
  ZYGOTE_STORE_.remove ZYGOTE_WIFI_CONFIGURED_KEY_

is_missing_wifi_configuration_error exception/any -> bool:
  return "$exception".contains "wifi ssid not provided"

has_firmware_wifi_configuration_ -> bool:
  ssid := firmware.config[WIFI_SSID_KEY_]
  return ssid is string and ssid != ""

ZYGOTE_STORE_       ::= storage.Bucket.open --flash "github.com/kasperl/toit-zygote"
ZYGOTE_STATE_KEY_   ::= "state"
ZYGOTE_STATE_SETUP_ ::= "setup"
ZYGOTE_WIFI_CONFIGURED_KEY_ ::= "wifi-configured"
WIFI_SSID_KEY_      ::= "wifi.ssid"
