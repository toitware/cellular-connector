// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import cellular
import device
import encoding.ubjson
import gpio
import log
import net

class Configuration:
  is_always_online/bool
  op/string?
  apn/string
  bands/List?
  rats/List?

  constructor .apn --.is_always_online=true --.op=null --.bands=null --.rats=null:


class Connector:
  static SUSTAIN_FOR_DURATION_ ::= Duration --ms=100
  static CONFIGURE_TIMEOUT_ ::= Duration --s=30
  static CONNECT_TIMEOUT_PSM_TIMEOUT_ ::= Duration --s=15
  static CONNECT_AUTOMATIC_TIMEOUT_ ::= Duration --s=25
  static CONNECT_KNOWN_TIMEOUT_ ::= Duration --s=10

  driver_/cellular.Cellular
  logger_/log.Logger?

  store_/StateStore ::= StateStore

  rts_/gpio.Pin? ::= ?
  rx_/gpio.Pin? ::= ?

  config_/Configuration

  constructor .driver_ config --logger=null --rx=null --rts=null:
    config_ = config
    logger_ = logger
    rts_ = rts
    rx_ = rx

  connect -> net.Interface:
    wait_for_modem_

    try:
      if store_.take_is_psm and not config_.is_always_online:
        logger_.debug "connecting from PSM"
        configure_and_connect_from_psm_
      else:
        configure_and_connect_default_
      return driver_.network_interface
    finally: | is_exception _ |
      if is_exception: close

  configure_and_connect_from_psm_:
    cellular_info := load_cellular_info_
    cellular_info.total_attempts++
    store_cellular_info_ cellular_info
    try:
      operator/string? := config_.op
      if operator == "": operator = null
      with_timeout CONNECT_TIMEOUT_PSM_TIMEOUT_:
        logger_.debug "connecting" --tags={"operator": operator}
        driver_.connect_psm
        logger_.debug "connected successfully"
        cellular_info.total_attempts = 0
        store_cellular_info_ cellular_info

    finally: | is_exception _ |
      if not is_exception and driver_.use_psm: store_.set_use_psm

      if is_exception and cellular_info.total_attempts > 0:
        // Detach if connect failed (that will force a full scan at next connect).
        logger_.debug "failed, detach from network"
        // TODO: We should probably only do this after e.g. 10 failed attempts.
        catch --trace: driver_.detach

  configure_and_connect_default_:
    // Print out the modem information.
    logger_.debug "initialized" --tags={
      "model": driver_.model,
      "version": driver_.version,
      "iccid": driver_.iccid,
    }

    // Configure the chip. This may make the chip reboot a few times.
    with_timeout CONFIGURE_TIMEOUT_:
      driver_.configure config_.apn --bands=config_.bands --rats=config_.rats

    cellular_info := load_cellular_info_
    cellular_info.total_attempts++
    logger_.debug "state" --tags={
      "latest_operator": cellular_info.latest_operator,
      "operators": cellular_info.operators,
      "connect_attempts": cellular_info.connect_attempts,
      "total_attempts": cellular_info.connect_attempts,
    }
    try:
      configured_operator := config_.op
      operator/cellular.Operator? := null
      driver_.enable_radio

      if configured_operator and configured_operator != "":
        cellular_info.connect_attempts++
        store_cellular_info_ cellular_info

        operator = cellular.Operator configured_operator
        if connect_to_operator_ operator --attempt=cellular_info.connect_attempts:
          cellular_info.connect_attempts = 0
          store_cellular_info_ cellular_info
          return
        throw "failed to connect to operator: '$operator'"

      operator = cellular_info.latest_operator
      // Attempt a stored operator?
      if operator:
        if cellular_info.connect_attempts < 2:
          logger_.debug "attempt connect to known operator"
        else:
          // Last attempt to connect to known operator.
          cellular_info.latest_operator = null
          cellular_info.connect_attempts = 0
      else if cellular_info.connect_attempts < 3:
        logger_.debug "attempt modem's automatic connect"
      else if cellular_info.connect_attempts > 30:
        // Something is wrong! Reset state.
        reset_info_ cellular_info
      else:
        if cellular_info.operators.is_empty:
          logger_.debug "scan for available operators"
          try:
            cellular_info.operators = driver_.scan_for_operators
          finally: | is_exception _ |
            if is_exception:
              reset_info_ cellular_info
              store_cellular_info_ cellular_info

        logger_.debug "attempt connect to scanned operator"
        connected := false
        try:
          connected = connect_to_operators_ cellular_info
          if connected:
            return
        finally:
          if cellular_info.operators.is_empty and not connected:
            // We have tried all scanned operators. Reset state.
            reset_info_ cellular_info
            store_cellular_info_ cellular_info
        throw "CONNECTION FAILED"

      cellular_info.connect_attempts++
      store_cellular_info_ cellular_info
      if connect_to_operator_ operator --attempt=cellular_info.connect_attempts:
        if not operator: operator = driver_.get_connected_operator
        reset_info_ cellular_info
        cellular_info.latest_operator = operator
        store_cellular_info_ cellular_info
      else:
        throw "CONNECTION FAILED"

    finally: | is_exception _ |
      if not is_exception and driver_.use_psm: store_.set_use_psm

      if is_exception:
        driver_.disable_radio
        if cellular_info.total_attempts == 10:
          // Detach if connect failed (that will force a full scan at next connect).
          logger_.debug "failed, detach from network"
          catch --trace: driver_.detach


  connect_to_operators_ cellular_info/CellularInfo -> bool:
    while not cellular_info.operators.is_empty:
      operator/cellular.Operator := cellular_info.operators.last
      cellular_info.operators.remove_last
      cellular_info.connect_attempts++
      store_cellular_info_ cellular_info
      if connect_to_operator_ operator --attempt=1:
        cellular_info.latest_operator = operator
        return true
    return false

  connect_to_operator_ operator/cellular.Operator? --attempt/int? -> bool:
    timeout := operator ? CONNECT_KNOWN_TIMEOUT_ : CONNECT_AUTOMATIC_TIMEOUT_
    catch --unwind=(: | exception | exception != DEADLINE_EXCEEDED_ERROR):
      with_timeout timeout:
        logger_.debug "connecting" --tags={"operator": operator, "attempt": attempt}
        result := driver_.connect --operator=operator
        if result: logger_.debug "connected successfully"
        else: logger_.debug "connection failed"
        return result
    return false

  close:
    try:
      try:
        // Tell chip to turn off.
        driver_.close
      finally: | is_exception _ |
        if is_exception:
          // If the chip was recently rebooted, wait for it to be responsive before
          // communicating with it.
          driver_.wait_for_ready
          driver_.close
    finally:
      // Wait for chip to signal power-off.
      if rts_:
        rts_.config --output
        rts_.set 0
      wait_for_quiescent_


  /** Wait for the modem to report ready. */
  wait_for_modem_:
    try:
      try:
        with_timeout --ms=15_000:
          driver_.wait_for_ready
        logger_.debug "modem ready"
      finally: | is_exception _ |
        if is_exception:
          logger_.debug "did not report ready, closing modem"
          with_timeout --ms=5_000:
            driver_.close
    finally: | is_exception _ |
      if is_exception:
        logger_.debug "did not close, trying hardware recover of modem"
        with_timeout --ms=15_000:
          driver_.recover_modem

  // Block until a value has been sustained for at least $SUSTAIN_FOR_DURATION_.
  wait_for_quiescent_:
    logger_.debug "waiting for quiescent rx pin"
    rx_.config --input
    while true:
      value := rx_.get

      // See if value is sustained for the required amount.
      e := catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout SUSTAIN_FOR_DURATION_:
          rx_.wait_for 1 - value

      // If we timed out, we're done.
      if e:
        logger_.debug "waiting for quiescent rx pin -> done" --tags={"value": value}
        return

  load_cellular_info_ -> CellularInfo:
    bytes := store_.load
    if bytes:
      e := catch --trace:
        return CellularInfo.from_bytes bytes
      if e: store_.remove
    return CellularInfo

  store_cellular_info_ info/CellularInfo -> bool:
    return store_.store info.to_byte_array

reset_info_ info/CellularInfo -> none:
  info.operators = []
  info.connect_attempts = 0
  info.total_attempts = 0
  info.latest_operator = null

class CellularInfo:
  operators/List := []
  connect_attempts/int := 0
  total_attempts := 0
  latest_operator/cellular.Operator? := null

  constructor:

  constructor.from_bytes bytes/ByteArray:
    values := ubjson.decode bytes
    if values.size != 4:
      (StateStore).remove
      throw "invalid info bytes"
    operators = values_to_operators_ values[0]
    connect_attempts = values[1]
    total_attempts = values[2]
    latest_operator = values[3] ? value_to_operator values[3] : null

  stringify -> string:
    return "operators: $operators, connect_attempts: $connect_attempts, total_attempts: $total_attempts, latest_operator: $latest_operator"

  to_byte_array -> ByteArray:
    return ubjson.encode [operators_to_values_, connect_attempts, total_attempts, latest_operator ? [latest_operator.op, latest_operator.rat] : null]

  values_to_operators_ values/List:
    res := []
    values.do: | value/List |
      res.add
        value_to_operator value
    return res

  operators_to_values_ -> List:
    res := []
    operators.do: | operator/cellular.Operator |
      res.add
        operator_to_value operator
    return res

  operator_to_value operator/cellular.Operator -> List:
    return [operator.op, operator.rat]

  value_to_operator value/List -> cellular.Operator:
    if value.size != 2: throw "invalid operator value"

    return cellular.Operator value[0] --rat=value[1]

class StateStore:
  static STORE_INFO_KEY_ ::= "connect info"
  static STORE_PSM_KEY_ ::= "is psm"
  store_ := device.FlashStore

  constructor:

  store bytes/ByteArray -> bool:
    store_.set STORE_INFO_KEY_ bytes
    // TODO can we return bool here?
    return true

  load -> ByteArray?:
    return store_.get STORE_INFO_KEY_

  remove:
    store_.delete STORE_INFO_KEY_

  take_is_psm -> bool:
    is_psm := store_.get STORE_PSM_KEY_
    if is_psm: store_.delete STORE_PSM_KEY_
    return is_psm ? true : false

  set_use_psm -> none:
    store_.set STORE_PSM_KEY_ (ByteArray 0)
