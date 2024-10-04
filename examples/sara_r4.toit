// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import cellular
import cellular-connector show Connector Configuration
import gpio
import http show Client
import log
import net
import u-blox-cellular.sara-r4 show SaraR4
import uart


TX-PIN-NUM ::= 16
RX-PIN-NUM ::= 17
PWR-ON-NUM ::= 18
RESET-N-NUM ::= 4

main:
  pwr-on :=  gpio.Pin PWR-ON-NUM
  pwr-on.configure --output --open-drain
  pwr-on.set 1
  reset-n := gpio.Pin RESET-N-NUM
  reset-n.configure --output --open-drain
  reset-n.set 1
  tx := gpio.Pin TX-PIN-NUM
  rx := gpio.Pin RX-PIN-NUM

  port := uart.Port --tx=tx --rx=rx --baud-rate=cellular.Cellular.DEFAULT-BAUD-RATE

  driver :=  SaraR4 port --pwr-on=(gpio.InvertedPin pwr-on) --reset-n=(gpio.InvertedPin reset-n) --logger=log.default --is-always-online=false
  configuration := Configuration "soracom.io" --bands=[8,20]

  connector := Connector driver configuration --logger=log.default --rx=rx

  connector.connect

  visit-google driver.network-interface

visit-google network-interface/net.Interface:
  host := "www.google.com"

  client := Client network-interface

  response := client.get host "/"

  bytes := 0
  while data := response.body.read:
    bytes += data.size

  log.default.info "Read $bytes bytes from http://$host/"
