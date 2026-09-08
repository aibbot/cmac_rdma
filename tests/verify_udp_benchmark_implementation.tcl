proc udp_benchmark_read_report {report_path} {
    if {![file exists $report_path]} {
        error "Required report is missing: $report_path"
    }
    set report_channel [open $report_path r]
    set report_text [read $report_channel]
    close $report_channel
    return $report_text
}

proc udp_benchmark_utilization_row {report_path instance_name} {
    foreach line [split [udp_benchmark_read_report $report_path] "\n"] {
        set fields [split $line "|"]
        if {[llength $fields] < 12 ||
            [string trim [lindex $fields 1]] ne $instance_name} {
            continue
        }

        set metrics [dict create \
            LUT    [string trim [lindex $fields 3]] \
            FF     [string trim [lindex $fields 7]] \
            RAMB36 [string trim [lindex $fields 8]] \
            RAMB18 [string trim [lindex $fields 9]] \
            URAM   [string trim [lindex $fields 10]] \
            DSP    [string trim [lindex $fields 11]]]
        foreach metric_name [dict keys $metrics] {
            set metric_value [dict get $metrics $metric_name]
            if {![string is integer -strict $metric_value]} {
                error "Could not parse $metric_name for $instance_name in $report_path"
            }
        }
        return $metrics
    }
    error "Could not find $instance_name in $report_path"
}

proc udp_benchmark_timing_summary {report_path} {
    set found_summary_header 0
    foreach line [split [udp_benchmark_read_report $report_path] "\n"] {
        if {[string first "WNS(ns)" $line] >= 0 &&
            [string first "WPWS(ns)" $line] >= 0} {
            set found_summary_header 1
            continue
        }
        if {!$found_summary_header} {
            continue
        }

        set fields [regexp -all -inline {\S+} $line]
        if {[llength $fields] < 9 ||
            ![string is double -strict [lindex $fields 0]] ||
            ![string is double -strict [lindex $fields 4]] ||
            ![string is double -strict [lindex $fields 8]]} {
            continue
        }
        return [dict create \
            WNS [lindex $fields 0] \
            WHS [lindex $fields 4] \
            WPWS [lindex $fields 8]]
    }
    error "Could not parse global timing summary from $report_path"
}

proc udp_benchmark_endpoint_slack {report_path} {
    set report_text [udp_benchmark_read_report $report_path]
    if {![regexp {Slack \([^)]*\) :[[:space:]]*([-+]?[0-9]+(\.[0-9]+)?)ns} \
          $report_text -> slack]} {
        error "Could not parse endpoint slack from $report_path"
    }
    if {![string is double -strict $slack]} {
        error "Endpoint slack is not numeric in $report_path: $slack"
    }
    return $slack
}

proc verify_udp_benchmark_implementation {project_dir} {
    set tests_dir [file join $project_dir tests]
    set baseline_utilization [file join $tests_dir \
        udp_benchmark_baseline_hierarchical_utilization.rpt]
    set implementation_utilization [file join $tests_dir \
        udp_benchmark_hierarchical_utilization.rpt]
    set baseline_timing [file join $tests_dir \
        udp_benchmark_baseline_timing_summary.rpt]
    set implementation_timing [file join $tests_dir \
        udp_benchmark_timing_summary.rpt]
    set baseline_endpoint_timing [file join $tests_dir \
        udp_benchmark_baseline_endpoint_timing.rpt]
    set implementation_endpoint_timing [file join $tests_dir \
        udp_benchmark_endpoint_timing.rpt]
    set comparison_report [file join $tests_dir \
        udp_benchmark_implementation_comparison.rpt]

    set baseline_total [udp_benchmark_utilization_row \
        $baseline_utilization cmac_usplus_0_exdes]
    set implementation_total [udp_benchmark_utilization_row \
        $implementation_utilization cmac_usplus_0_exdes]
    set baseline_endpoint [udp_benchmark_utilization_row \
        $baseline_utilization i_cmac_usplus_0_ping_responder]
    set implementation_endpoint [udp_benchmark_utilization_row \
        $implementation_utilization i_cmac_usplus_0_ping_responder]
    set implementation_global_timing \
        [udp_benchmark_timing_summary $implementation_timing]
    set baseline_endpoint_slack \
        [udp_benchmark_endpoint_slack $baseline_endpoint_timing]
    set implementation_endpoint_slack \
        [udp_benchmark_endpoint_slack $implementation_endpoint_timing]

    set failures [list]
    foreach metric_name {LUT FF RAMB36 RAMB18 URAM DSP} {
        if {[dict get $implementation_total $metric_name] >
            [dict get $baseline_total $metric_name]} {
            lappend failures "total $metric_name increased"
        }
    }
    if {[dict get $implementation_endpoint LUT] >=
        [dict get $baseline_endpoint LUT] &&
        [dict get $implementation_endpoint FF] >=
        [dict get $baseline_endpoint FF]} {
        lappend failures "custom endpoint LUT and FF did not decrease"
    }
    foreach timing_name {WNS WHS WPWS} {
        if {[dict get $implementation_global_timing $timing_name] < 0.0} {
            lappend failures "global $timing_name is negative"
        }
    }
    if {$implementation_endpoint_slack < $baseline_endpoint_slack} {
        lappend failures "grant-to-output endpoint timing regressed"
    }

    set comparison_channel [open $comparison_report w]
    puts $comparison_channel "UDP benchmark implementation acceptance"
    puts $comparison_channel "baseline total:        $baseline_total"
    puts $comparison_channel "implementation total:  $implementation_total"
    puts $comparison_channel "baseline endpoint:     $baseline_endpoint"
    puts $comparison_channel "implementation endpoint: $implementation_endpoint"
    puts $comparison_channel "implementation timing: $implementation_global_timing"
    puts $comparison_channel "baseline endpoint slack: $baseline_endpoint_slack ns"
    puts $comparison_channel "implementation endpoint slack: $implementation_endpoint_slack ns"
    if {[llength $failures]} {
        puts $comparison_channel "result: FAIL"
        foreach failure $failures {
            puts $comparison_channel "failure: $failure"
        }
    } else {
        puts $comparison_channel "result: PASS"
    }
    close $comparison_channel

    if {[llength $failures]} {
        error "UDP benchmark implementation acceptance failed: [join $failures {; }]"
    }
}
