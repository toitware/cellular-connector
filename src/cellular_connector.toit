// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import cellular
import encoding.ubjson
import gpio
import log
import net
import system.storage

class Configuration:
  is-always-online/bool
  op/string?
  apn/string
  bands/List?
  rats/List?

  constructor .apn --.is-always-online=true --.op=null --.bands=null --.rats=null:


class Connector:
  static SUSTAIN-FOR-DURATION_ ::= Duration --ms=100
  static CONFIGURE-TIMEOUT_ ::= Duration --s=30
  static CONNECT-TIMEOUT-PSM-TIMEOUT_ ::= Duration --s=15
  static CONNECT-AUTOMATIC-TIMEOUT_ ::= Duration --s=25
  static CONNECT-KNOWN-TIMEOUT_ ::= Duration --s=10

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
    wait-for-modem_

    try:
      if store_.take-is-psm and not config_.is-always-online:
        logger_.debug "connecting from PSM"
        configure-and-connect-from-psm_
      else:
        configure-and-connect-default_
      return driver_.network-interface
    finally: | is-exception _ |
      if is-exception: close

  configure-and-connect-from-psm_:
    cellular-info := load-cellular-info_
    cellular-info.total-attempts++
    store-cellular-info_ cellular-info
    try:
      operator/string? := config_.op
      if operator == "": operator = null
      with-timeout CONNECT-TIMEOUT-PSM-TIMEOUT_:
        logger_.debug "connecting" --tags={"operator": operator}
        driver_.connect-psm
        logger_.debug "connected successfully"
        cellular-info.total-attempts = 0
        store-cellular-info_ cellular-info

    finally: | is-exception _ |
      if not is-exception and driver_.use-psm: store_.set-use-psm

      if is-exception and cellular-info.total-attempts > 0:
        // Detach if connect failed (that will force a full scan at next connect).
        logger_.debug "failed, detach from network"
        // TODO: We should probably only do this after e.g. 10 failed attempts.
        catch --trace: driver_.detach

  configure-and-connect-default_:
    // Print out the modem information.
    logger_.debug "initialized" --tags={
      "model": driver_.model,
      "version": driver_.version,
      "iccid": driver_.iccid,
    }

    // Configure the chip. This may make the chip reboot a few times.
    with-timeout CONFIGURE-TIMEOUT_:
      driver_.configure config_.apn --bands=config_.bands --rats=config_.rats

    cellular-info := load-cellular-info_
    cellular-info.total-attempts++
    logger_.debug "state" --tags={
      "latest_operator": cellular-info.latest-operator,
      "operators": cellular-info.operators,
      "connect_attempts": cellular-info.connect-attempts,
      "total_attempts": cellular-info.connect-attempts,
    }
    try:
      configured-operator := config_.op
      operator/cellular.Operator? := null
      driver_.enable-radio

      if configured-operator and configured-operator != "":
        cellular-info.connect-attempts++
        store-cellular-info_ cellular-info

        operator = cellular.Operator configured-operator
        if connect-to-operator_ operator --attempt=cellular-info.connect-attempts:
          cellular-info.connect-attempts = 0
          store-cellular-info_ cellular-info
          return
        throw "failed to connect to operator: '$operator'"

      operator = cellular-info.latest-operator
      // Attempt a stored operator?
      if operator:
        if cellular-info.connect-attempts < 2:
          logger_.debug "attempt connect to known operator"
        else:
          // Last attempt to connect to known operator.
          cellular-info.latest-operator = null
          cellular-info.connect-attempts = 0
      else if cellular-info.connect-attempts < 3:
        logger_.debug "attempt modem's automatic connect"
      else if cellular-info.connect-attempts > 30:
        // Something is wrong! Reset state.
        reset-info_ cellular-info
      else:
        if cellular-info.operators.is-empty:
          logger_.debug "scan for available operators"
          try:
            cellular-info.operators = driver_.scan-for-operators
          finally: | is-exception _ |
            if is-exception:
              reset-info_ cellular-info
              store-cellular-info_ cellular-info

        logger_.debug "attempt connect to scanned operator"
        connected := false
        try:
          connected = connect-to-operators_ cellular-info
          if connected:
            return
        finally:
          if cellular-info.operators.is-empty and not connected:
            // We have tried all scanned operators. Reset state.
            reset-info_ cellular-info
            store-cellular-info_ cellular-info
        throw "CONNECTION FAILED"

      cellular-info.connect-attempts++
      store-cellular-info_ cellular-info
      if connect-to-operator_ operator --attempt=cellular-info.connect-attempts:
        if not operator: operator = driver_.get-connected-operator
        reset-info_ cellular-info
        cellular-info.latest-operator = operator
        store-cellular-info_ cellular-info
      else:
        throw "CONNECTION FAILED"

    finally: | is-exception _ |
      if not is-exception and driver_.use-psm: store_.set-use-psm

      if is-exception:
        driver_.disable-radio
        if cellular-info.total-attempts == 10:
          // Detach if connect failed (that will force a full scan at next connect).
          logger_.debug "failed, detach from network"
          catch --trace: driver_.detach


  connect-to-operators_ cellular-info/CellularInfo -> bool:
    while not cellular-info.operators.is-empty:
      operator/cellular.Operator := cellular-info.operators.last
      cellular-info.operators.remove-last
      cellular-info.connect-attempts++
      store-cellular-info_ cellular-info
      if connect-to-operator_ operator --attempt=1:
        cellular-info.latest-operator = operator
        return true
    return false

  connect-to-operator_ operator/cellular.Operator? --attempt/int? -> bool:
    timeout := operator ? CONNECT-KNOWN-TIMEOUT_ : CONNECT-AUTOMATIC-TIMEOUT_
    catch --unwind=(: | exception | exception != DEADLINE-EXCEEDED-ERROR):
      with-timeout timeout:
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
      finally: | is-exception _ |
        if is-exception:
          // If the chip was recently rebooted, wait for it to be responsive before
          // communicating with it.
          driver_.wait-for-ready
          driver_.close
    finally:
      // Wait for chip to signal power-off.
      if rts_:
        rts_.configure --output
        rts_.set 0
      wait-for-quiescent_


  /** Wait for the modem to report ready. */
  wait-for-modem_:
    try:
      try:
        with-timeout --ms=15_000:
          driver_.wait-for-ready
        logger_.debug "modem ready"
      finally: | is-exception _ |
        if is-exception:
          logger_.debug "did not report ready, closing modem"
          with-timeout --ms=5_000:
            driver_.close
    finally: | is-exception _ |
      if is-exception:
        logger_.debug "did not close, trying hardware recover of modem"
        with-timeout --ms=15_000:
          driver_.recover-modem

  // Block until a value has been sustained for at least $SUSTAIN_FOR_DURATION_.
  wait-for-quiescent_:
    logger_.debug "waiting for quiescent rx pin"
    rx_.configure --input
    while true:
      value := rx_.get

      // See if value is sustained for the required amount.
      e := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        with-timeout SUSTAIN-FOR-DURATION_:
          rx_.wait-for 1 - value

      // If we timed out, we're done.
      if e:
        logger_.debug "waiting for quiescent rx pin -> done" --tags={"value": value}
        return

  load-cellular-info_ -> CellularInfo:
    bytes := store_.load
    if bytes:
      e := catch --trace:
        return CellularInfo.from-bytes bytes
      if e: store_.remove
    return CellularInfo

  store-cellular-info_ info/CellularInfo -> bool:
    return store_.store info.to-byte-array

reset-info_ info/CellularInfo -> none:
  info.operators = []
  info.connect-attempts = 0
  info.total-attempts = 0
  info.latest-operator = null

class CellularInfo:
  operators/List := []
  connect-attempts/int := 0
  total-attempts := 0
  latest-operator/cellular.Operator? := null

  constructor:

  constructor.from-bytes bytes/ByteArray:
    values := ubjson.decode bytes
    if values.size != 4:
      (StateStore).remove
      throw "invalid info bytes"
    operators = values-to-operators_ values[0]
    connect-attempts = values[1]
    total-attempts = values[2]
    latest-operator = values[3] ? value-to-operator values[3] : null

  stringify -> string:
    return "operators: $operators, connect_attempts: $connect-attempts, total_attempts: $total-attempts, latest_operator: $latest-operator"

  to-byte-array -> ByteArray:
    return ubjson.encode [operators-to-values_, connect-attempts, total-attempts, latest-operator ? [latest-operator.op, latest-operator.rat] : null]

  values-to-operators_ values/List:
    res := []
    values.do: | value/List |
      res.add
        value-to-operator value
    return res

  operators-to-values_ -> List:
    res := []
    operators.do: | operator/cellular.Operator |
      res.add
        operator-to-value operator
    return res

  operator-to-value operator/cellular.Operator -> List:
    return [operator.op, operator.rat]

  value-to-operator value/List -> cellular.Operator:
    if value.size != 2: throw "invalid operator value"

    return cellular.Operator value[0] --rat=value[1]

class StateStore:
  static STORE-PATH_ ::= "toit.io/cellular_connector"
  static STORE-INFO-KEY_ ::= "connect info"
  static STORE-PSM-KEY_ ::= "is psm"

  bucket_/storage.Bucket

  constructor:
    bucket_ = storage.Bucket.open --flash STORE-PATH_

  store bytes/ByteArray -> bool:
    bucket_[STORE-INFO-KEY_] = bytes
    // TODO can we return bool here?
    return true

  load -> ByteArray?:
    return bucket_.get STORE-INFO-KEY_

  remove:
    bucket_.remove STORE-INFO-KEY_

  take-is-psm -> bool:
    is-psm := bucket_.get STORE-PSM-KEY_
    if is-psm: bucket_.remove STORE-PSM-KEY_
    return is-psm ? true : false

  set-use-psm -> none:
    bucket_[STORE-PSM-KEY_] = #[]
