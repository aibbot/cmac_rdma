# Deterministic Vivado IP customization UI for the portable RDMA transport.
# The packaging script copies this file into the generated IP repository.

proc rdma_cycles_from_frequency {frequency_parameter divisor} {
  set frequency_hz [get_property value $frequency_parameter]
  set cycles [expr {wide($frequency_hz) / $divisor}]
  if {$cycles < 1} {
    return 1
  }
  return $cycles
}

proc init_gui {IPINST} {
  ipgui::add_param $IPINST -name Component_Name

  set configuration_page [ipgui::add_page $IPINST -name {Configuration}]
  set identity_group [ipgui::add_group $IPINST -name {Identity and clock} \
    -parent $configuration_page]
  ipgui::add_param $IPINST -name ACLK_FREQ_HZ -parent $identity_group
  ipgui::add_param $IPINST -name LOCAL_MAC -parent $identity_group
  ipgui::add_param $IPINST -name LOCAL_QPN -parent $identity_group
  ipgui::add_param $IPINST -name BUILD_TAG -parent $identity_group

  set reliability_group [ipgui::add_group $IPINST \
    -name {Reliability and recovery} -parent $configuration_page]
  ipgui::add_param $IPINST -name ACK_TIMEOUT_CYCLES \
    -parent $reliability_group
  ipgui::add_param $IPINST -name RNR_TIMER_10US_CYCLES \
    -parent $reliability_group
  ipgui::add_param $IPINST -name MAX_RETRIES -parent $reliability_group
  ipgui::add_param $IPINST -name MAX_SEQUENCE_RECOVERIES \
    -parent $reliability_group
  ipgui::add_param $IPINST -name SEQUENCE_RECOVERY_QUIET_CYCLES \
    -parent $reliability_group

  set implementation_group [ipgui::add_group $IPINST \
    -name {Implementation} -parent $configuration_page]
  ipgui::add_param $IPINST -name FAST_BENCHMARK_MODE \
    -parent $implementation_group
  ipgui::add_param $IPINST -name ENABLE_EXTERNAL_PAYLOAD \
    -parent $implementation_group
}

# Changing ACLK_FREQ_HZ refreshes the physical-time defaults. Both cycle-count
# fields remain ordinary user parameters and may be overridden afterwards.
proc update_PARAM_VALUE.ACK_TIMEOUT_CYCLES {
  PARAM_VALUE.ACK_TIMEOUT_CYCLES
  PARAM_VALUE.ACLK_FREQ_HZ
} {
  set cycles [rdma_cycles_from_frequency \
    ${PARAM_VALUE.ACLK_FREQ_HZ} 1000]
  set_property value $cycles ${PARAM_VALUE.ACK_TIMEOUT_CYCLES}
}

proc validate_PARAM_VALUE.ACK_TIMEOUT_CYCLES {
  PARAM_VALUE.ACK_TIMEOUT_CYCLES
} {
  return true
}

proc update_PARAM_VALUE.ACLK_FREQ_HZ {PARAM_VALUE.ACLK_FREQ_HZ} {}

proc validate_PARAM_VALUE.ACLK_FREQ_HZ {PARAM_VALUE.ACLK_FREQ_HZ} {
  return true
}

proc update_PARAM_VALUE.BUILD_TAG {PARAM_VALUE.BUILD_TAG} {}

proc validate_PARAM_VALUE.BUILD_TAG {PARAM_VALUE.BUILD_TAG} {
  return true
}

proc update_PARAM_VALUE.FAST_BENCHMARK_MODE {
  PARAM_VALUE.FAST_BENCHMARK_MODE
} {}

proc validate_PARAM_VALUE.FAST_BENCHMARK_MODE {
  PARAM_VALUE.FAST_BENCHMARK_MODE
} {
  return true
}

proc update_PARAM_VALUE.LOCAL_MAC {PARAM_VALUE.LOCAL_MAC} {}

proc validate_PARAM_VALUE.LOCAL_MAC {PARAM_VALUE.LOCAL_MAC} {
  return true
}

proc update_PARAM_VALUE.LOCAL_QPN {PARAM_VALUE.LOCAL_QPN} {}

proc validate_PARAM_VALUE.LOCAL_QPN {PARAM_VALUE.LOCAL_QPN} {
  return true
}

proc update_PARAM_VALUE.MAX_RETRIES {PARAM_VALUE.MAX_RETRIES} {}

proc validate_PARAM_VALUE.MAX_RETRIES {PARAM_VALUE.MAX_RETRIES} {
  return true
}

proc update_PARAM_VALUE.MAX_SEQUENCE_RECOVERIES {
  PARAM_VALUE.MAX_SEQUENCE_RECOVERIES
} {}

proc validate_PARAM_VALUE.MAX_SEQUENCE_RECOVERIES {
  PARAM_VALUE.MAX_SEQUENCE_RECOVERIES
} {
  return true
}

proc update_PARAM_VALUE.RNR_TIMER_10US_CYCLES {
  PARAM_VALUE.RNR_TIMER_10US_CYCLES
  PARAM_VALUE.ACLK_FREQ_HZ
} {
  set cycles [rdma_cycles_from_frequency \
    ${PARAM_VALUE.ACLK_FREQ_HZ} 100000]
  set_property value $cycles ${PARAM_VALUE.RNR_TIMER_10US_CYCLES}
}

proc validate_PARAM_VALUE.RNR_TIMER_10US_CYCLES {
  PARAM_VALUE.RNR_TIMER_10US_CYCLES
} {
  return true
}

proc update_PARAM_VALUE.SEQUENCE_RECOVERY_QUIET_CYCLES {
  PARAM_VALUE.SEQUENCE_RECOVERY_QUIET_CYCLES
} {}

proc validate_PARAM_VALUE.SEQUENCE_RECOVERY_QUIET_CYCLES {
  PARAM_VALUE.SEQUENCE_RECOVERY_QUIET_CYCLES
} {
  return true
}

proc update_MODELPARAM_VALUE.LOCAL_MAC {
  MODELPARAM_VALUE.LOCAL_MAC
  PARAM_VALUE.LOCAL_MAC
} {
  set_property value [get_property value ${PARAM_VALUE.LOCAL_MAC}] \
    ${MODELPARAM_VALUE.LOCAL_MAC}
}

proc update_MODELPARAM_VALUE.LOCAL_QPN {
  MODELPARAM_VALUE.LOCAL_QPN
  PARAM_VALUE.LOCAL_QPN
} {
  set_property value [get_property value ${PARAM_VALUE.LOCAL_QPN}] \
    ${MODELPARAM_VALUE.LOCAL_QPN}
}

proc update_MODELPARAM_VALUE.ACLK_FREQ_HZ {
  MODELPARAM_VALUE.ACLK_FREQ_HZ
  PARAM_VALUE.ACLK_FREQ_HZ
} {
  set_property value [get_property value ${PARAM_VALUE.ACLK_FREQ_HZ}] \
    ${MODELPARAM_VALUE.ACLK_FREQ_HZ}
}

proc update_MODELPARAM_VALUE.ACK_TIMEOUT_CYCLES {
  MODELPARAM_VALUE.ACK_TIMEOUT_CYCLES
  PARAM_VALUE.ACK_TIMEOUT_CYCLES
} {
  set_property value [get_property value ${PARAM_VALUE.ACK_TIMEOUT_CYCLES}] \
    ${MODELPARAM_VALUE.ACK_TIMEOUT_CYCLES}
}

proc update_MODELPARAM_VALUE.MAX_RETRIES {
  MODELPARAM_VALUE.MAX_RETRIES
  PARAM_VALUE.MAX_RETRIES
} {
  set_property value [get_property value ${PARAM_VALUE.MAX_RETRIES}] \
    ${MODELPARAM_VALUE.MAX_RETRIES}
}

proc update_MODELPARAM_VALUE.MAX_SEQUENCE_RECOVERIES {
  MODELPARAM_VALUE.MAX_SEQUENCE_RECOVERIES
  PARAM_VALUE.MAX_SEQUENCE_RECOVERIES
} {
  set_property value \
    [get_property value ${PARAM_VALUE.MAX_SEQUENCE_RECOVERIES}] \
    ${MODELPARAM_VALUE.MAX_SEQUENCE_RECOVERIES}
}

proc update_MODELPARAM_VALUE.SEQUENCE_RECOVERY_QUIET_CYCLES {
  MODELPARAM_VALUE.SEQUENCE_RECOVERY_QUIET_CYCLES
  PARAM_VALUE.SEQUENCE_RECOVERY_QUIET_CYCLES
} {
  set_property value \
    [get_property value ${PARAM_VALUE.SEQUENCE_RECOVERY_QUIET_CYCLES}] \
    ${MODELPARAM_VALUE.SEQUENCE_RECOVERY_QUIET_CYCLES}
}

proc update_MODELPARAM_VALUE.RNR_TIMER_10US_CYCLES {
  MODELPARAM_VALUE.RNR_TIMER_10US_CYCLES
  PARAM_VALUE.RNR_TIMER_10US_CYCLES
} {
  set_property value [get_property value ${PARAM_VALUE.RNR_TIMER_10US_CYCLES}] \
    ${MODELPARAM_VALUE.RNR_TIMER_10US_CYCLES}
}

proc update_MODELPARAM_VALUE.FAST_BENCHMARK_MODE {
  MODELPARAM_VALUE.FAST_BENCHMARK_MODE
  PARAM_VALUE.FAST_BENCHMARK_MODE
} {
  set_property value [get_property value ${PARAM_VALUE.FAST_BENCHMARK_MODE}] \
    ${MODELPARAM_VALUE.FAST_BENCHMARK_MODE}
}

proc update_MODELPARAM_VALUE.BUILD_TAG {
  MODELPARAM_VALUE.BUILD_TAG
  PARAM_VALUE.BUILD_TAG
} {
  set_property value [get_property value ${PARAM_VALUE.BUILD_TAG}] \
    ${MODELPARAM_VALUE.BUILD_TAG}
}
