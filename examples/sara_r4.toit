// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import cellular
import cellular_connector show Connector Configuration
import gpio
import http show Client
import log
import net
import u_blox_cellular.sara_r4 show SaraR4
import uart


TX_PIN_NUM ::= 16
RX_PIN_NUM ::= 17
PWR_ON_NUM ::= 18
RESET_N_NUM ::= 4

main:
  pwr_on :=  gpio.Pin PWR_ON_NUM
  pwr_on.config --output --open_drain
  pwr_on.set 1
  reset_n := gpio.Pin RESET_N_NUM
  reset_n.config --output --open_drain
  reset_n.set 1
  tx := gpio.Pin TX_PIN_NUM
  rx := gpio.Pin RX_PIN_NUM

  port := uart.Port --tx=tx --rx=rx --baud_rate=cellular.Cellular.DEFAULT_BAUD_RATE

  driver :=  SaraR4 port --pwr_on=(gpio.InvertedPin pwr_on) --reset_n=(gpio.InvertedPin reset_n) --logger=log.default --is_always_online=false
  configuration := Configuration "soracom.io" --bands=[8,20]

  connector := Connector driver configuration --logger=log.default --rx=rx

  connector.connect

  visit_google driver.network_interface

visit_google network_interface/net.Interface:
  host := "www.google.com"

  client := Client network_interface

  response := client.get host "/"

  bytes := 0
  while data := response.body.read:
    bytes += data.size

  log.default.info "Read $bytes bytes from http://$host/"
