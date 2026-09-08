proc configure_existing_vio {} {
    set vio [get_ips vio_0]
    set_property CONFIG.SIGNAL_CLOCK.FREQ_HZ {322265625} $vio

    generate_target all $vio
    export_ip_user_files -of_objects $vio -no_script -sync -force

    set vio_run [get_runs -quiet vio_0_synth_1]
    if {![llength $vio_run]} {
        create_ip_run $vio
        set vio_run [get_runs vio_0_synth_1]
    }
    return $vio_run
}

proc configure_udp_benchmark_vio {project_dir} {
    set default_payload_length 0x2328
    set udp_vio [get_ips -quiet udp_benchmark_vio]
    if {![llength $udp_vio]} {
        create_ip \
            -name vio \
            -vendor xilinx.com \
            -library ip \
            -version 3.0 \
            -module_name udp_benchmark_vio \
            -dir [file join $project_dir cmac_usplus_0_ex.srcs sources_1 ip]
        set udp_vio [get_ips udp_benchmark_vio]
    }

    set_property -dict [list \
        CONFIG.SIGNAL_CLOCK.FREQ_HZ {322265625} \
        CONFIG.C_NUM_PROBE_IN {3} \
        CONFIG.C_NUM_PROBE_OUT {9} \
        CONFIG.C_PROBE_IN0_WIDTH {32} \
        CONFIG.C_PROBE_IN1_WIDTH {40} \
        CONFIG.C_PROBE_IN2_WIDTH {32} \
        CONFIG.C_PROBE_OUT0_WIDTH {1} \
        CONFIG.C_PROBE_OUT0_INIT_VAL {0x0} \
        CONFIG.C_PROBE_OUT1_WIDTH {1} \
        CONFIG.C_PROBE_OUT1_INIT_VAL {0x0} \
        CONFIG.C_PROBE_OUT2_WIDTH {16} \
        CONFIG.C_PROBE_OUT2_INIT_VAL $default_payload_length \
        CONFIG.C_PROBE_OUT3_WIDTH {32} \
        CONFIG.C_PROBE_OUT3_INIT_VAL {0x00000000} \
        CONFIG.C_PROBE_OUT4_WIDTH {48} \
        CONFIG.C_PROBE_OUT4_INIT_VAL {0x107C615DE25B} \
        CONFIG.C_PROBE_OUT5_WIDTH {32} \
        CONFIG.C_PROBE_OUT5_INIT_VAL {0xC0A86507} \
        CONFIG.C_PROBE_OUT6_WIDTH {16} \
        CONFIG.C_PROBE_OUT6_INIT_VAL {0x1389} \
        CONFIG.C_PROBE_OUT7_WIDTH {16} \
        CONFIG.C_PROBE_OUT7_INIT_VAL {0x1389} \
        CONFIG.C_PROBE_OUT8_WIDTH {4} \
        CONFIG.C_PROBE_OUT8_INIT_VAL {0xF}] $udp_vio

    set configured_payload_length \
        [get_property CONFIG.C_PROBE_OUT2_INIT_VAL $udp_vio]
    if {[catch {expr {$configured_payload_length == $default_payload_length}} \
         payload_matches] || !$payload_matches} {
        error "udp_benchmark_vio payload default is $configured_payload_length, expected 9000"
    }

    reset_target all $udp_vio
    generate_target all $udp_vio
    export_ip_user_files -of_objects $udp_vio -no_script -sync -force

    set udp_vio_xci [get_property IP_FILE $udp_vio]
    if {![file exists $udp_vio_xci]} {
        error "udp_benchmark_vio XCI is missing: $udp_vio_xci"
    }
    set udp_vio_xci_channel [open $udp_vio_xci r]
    set udp_vio_xci_text [read $udp_vio_xci_channel]
    close $udp_vio_xci_channel
    if {![regexp {C_PROBE_OUT2_INIT_VAL.*0x2328} $udp_vio_xci_text]} {
        error "udp_benchmark_vio XCI was not regenerated with a 9000-byte default"
    }

    set udp_vio_run [get_runs -quiet udp_benchmark_vio_synth_1]
    if {![llength $udp_vio_run]} {
        create_ip_run $udp_vio
        set udp_vio_run [get_runs udp_benchmark_vio_synth_1]
    }
    return $udp_vio_run
}
