# Instantiate the generated IP from a clean consumer project and verify the
# public customization contract. Run after package_rdma_transport_ip.tcl.

set vivado_version [version -short]
if {![string match "2025.2*" $vivado_version]} {
  error "Vivado 2025.2 is required; found $vivado_version"
}

set script_dir [file dirname [file normalize [info script]]]
set rdma_dir [file normalize [file join $script_dir ..]]
set rtl_dir [file join $rdma_dir rtl]
set source_manifest [file join $script_dir rdma_transport_ip_sources.tcl]
set package_root [file join $rdma_dir build ip_repo]
set package_dir [file join $package_root \
  cmac_usplus_0_rdma_transport_ip_1_0]
set component_file [file join $package_dir component.xml]
set build_dir [file join $rdma_dir build ip_package_consumer]
set project_dir [file join $build_dir project]

if {![file exists $source_manifest]} {
  error "RDMA transport IP source manifest is missing: $source_manifest"
}
source $source_manifest

if {![file exists $component_file]} {
  error "Packaged RDMA transport IP is missing: $component_file"
}

package require sha256
set packaged_source_dir [file join $package_dir src]
set packaged_source_names [rdma_transport_ip_source_names]
foreach source_name $packaged_source_names {
  set authoritative_source [file join $rtl_dir $source_name]
  set packaged_source [file join $packaged_source_dir $source_name]
  if {![file exists $authoritative_source] || ![file exists $packaged_source]} {
    error "Missing authoritative or packaged RDMA source: $source_name"
  }
  set authoritative_hash [string tolower \
    [::sha2::sha256 -hex -filename $authoritative_source]]
  set packaged_hash [string tolower \
    [::sha2::sha256 -hex -filename $packaged_source]]
  if {$authoritative_hash ne $packaged_hash} {
    error "Packaged RDMA source is stale: $source_name authoritative=$authoritative_hash packaged=$packaged_hash"
  }
  puts "RDMA_TRANSPORT_IP_SOURCE_HASH file=$source_name \
sha256=$authoritative_hash"
}

if {[file tail $build_dir] ne "ip_package_consumer" ||
    [file dirname [file dirname $build_dir]] ne $rdma_dir} {
  error "Refusing to clean unexpected package-check directory: $build_dir"
}
if {[file exists $build_dir]} {
  file delete -force $build_dir
}

create_project -force rdma_transport_ip_consumer $project_dir \
  -part xczu47dr-fsvg1517-1-i
set_property ip_repo_paths $package_root [current_project]
update_ip_catalog -rebuild

set vlnv user.org:user:cmac_usplus_0_rdma_transport_ip:1.0
set definitions [get_ipdefs -all $vlnv]
if {[llength $definitions] != 1} {
  error "Expected one IP definition for $vlnv; found $definitions"
}

set module_name rdma_transport_smoke
set xci_file [create_ip -vlnv $vlnv -module_name $module_name]
set packaged_ip [get_ips $module_name]
if {[llength $packaged_ip] != 1 || ![file exists $xci_file]} {
  error "Failed to instantiate packaged RDMA transport IP"
}

proc expect_config {ip name expected} {
  set actual [get_property CONFIG.$name $ip]
  if {$actual ne "$expected"} {
    error "Unexpected CONFIG.$name: expected $expected, found $actual"
  }
}

expect_config $packaged_ip ACLK_FREQ_HZ 250000000
expect_config $packaged_ip ACK_TIMEOUT_CYCLES 250000
expect_config $packaged_ip RNR_TIMER_10US_CYCLES 2500
expect_config $packaged_ip FAST_BENCHMARK_MODE {"0"}

set_property CONFIG.ACLK_FREQ_HZ 100000000 $packaged_ip
expect_config $packaged_ip ACLK_FREQ_HZ 100000000
expect_config $packaged_ip ACK_TIMEOUT_CYCLES 100000
expect_config $packaged_ip RNR_TIMER_10US_CYCLES 1000

set_property CONFIG.ACK_TIMEOUT_CYCLES 777777 $packaged_ip
set_property CONFIG.RNR_TIMER_10US_CYCLES 3333 $packaged_ip
expect_config $packaged_ip ACK_TIMEOUT_CYCLES 777777
expect_config $packaged_ip RNR_TIMER_10US_CYCLES 3333

set_property CONFIG.FAST_BENCHMARK_MODE 1 $packaged_ip
expect_config $packaged_ip FAST_BENCHMARK_MODE 1

generate_target instantiation_template $packaged_ip
puts "RDMA_TRANSPORT_IP_PACKAGE_PASS vlnv=$vlnv xci=$xci_file"
close_project
