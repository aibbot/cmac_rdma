# Package the portable transport boundary as a reusable Vivado RTL IP.
# Run only with Vivado 2025.2; generated files stay below rdma/build/ip_repo.

set script_dir [file dirname [file normalize [info script]]]
set rdma_dir [file normalize [file join $script_dir ..]]
set rtl_dir [file join $rdma_dir rtl]
set readme_file [file join $rdma_dir README.md]
set architecture_file [file join $rdma_dir ARCHITECTURE.md]
set source_manifest [file join $script_dir rdma_transport_ip_sources.tcl]
set xgui_template [file join $script_dir \
  cmac_usplus_0_rdma_transport_ip_xgui.tcl]
set build_dir [file join $rdma_dir build ip_package]
set project_dir [file join $build_dir project]
set package_dir [file join $rdma_dir build ip_repo cmac_usplus_0_rdma_transport_ip_1_0]

if {![file exists $source_manifest]} {
  error "RDMA transport IP source manifest is missing: $source_manifest"
}
source $source_manifest

set vivado_version [version -short]
if {![string match "2025.2*" $vivado_version]} {
  error "Vivado 2025.2 is required; found $vivado_version"
}

set_param general.maxThreads 8
file mkdir $build_dir
if {[file tail $package_dir] ne "cmac_usplus_0_rdma_transport_ip_1_0" ||
    [file tail [file dirname $package_dir]] ne "ip_repo"} {
  error "Refusing to clean unexpected IP package directory: $package_dir"
}
if {[file exists $package_dir]} {
  file delete -force $package_dir
}
file mkdir [file dirname $package_dir]

create_project -force cmac_usplus_0_rdma_transport_ip_pack $project_dir \
  -part xczu47dr-fsvg1517-1-i
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set source_files [rdma_transport_ip_source_files $rtl_dir]

foreach support_file [list $readme_file $architecture_file $xgui_template] {
  if {![file exists $support_file]} {
    error "RDMA transport IP support file is missing: $support_file"
  }
}

foreach source_file $source_files {
  if {![file exists $source_file]} {
    error "RDMA transport IP source is missing: $source_file"
  }
  add_files -norecurse -fileset sources_1 $source_file
  set_property file_type SystemVerilog [get_files $source_file]
}

set_property top cmac_usplus_0_rdma_transport_ip [get_filesets sources_1]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $package_dir -vendor user.org -library user \
  -taxonomy /UserIP -import_files -set_current true
set core [ipx::current_core]
set_property name cmac_usplus_0_rdma_transport_ip $core
set_property display_name {100G RoCEv2 RDMA Transport Core} $core
set_property description \
  {Portable single-clock RoCEv2 transport with native configuration and AXI-Stream payload/network interfaces} \
  $core
set_property vendor_display_name {Custom FPGA RTL} $core
set_property version 1.0 $core
set_property core_revision 1 $core

proc set_parameter_range {core name minimum maximum description} {
  set parameter [ipx::get_user_parameters $name -of_objects $core]
  if {[llength $parameter] != 1} {
    error "Expected packaged parameter $name"
  }

  set_property value_validation_type range_long $parameter
  set_property value_validation_range_minimum $minimum $parameter
  set_property value_validation_range_maximum $maximum $parameter
  set_property description $description $parameter

  if {[get_property value_validation_type $parameter] ne "range_long" ||
      [get_property value_validation_range_minimum $parameter] ne "$minimum" ||
      [get_property value_validation_range_maximum $parameter] ne "$maximum"} {
    error "Failed to apply packaged parameter range for $name"
  }
}

set_parameter_range $core LOCAL_QPN 1 16777215 \
  {Local RC QP number; QPN zero is reserved}
set_parameter_range $core ACLK_FREQ_HZ 100000 2147483647 \
  {Portable core clock frequency in hertz}
set_parameter_range $core ACK_TIMEOUT_CYCLES 1 2147483647 \
  {ACK timeout in aclk cycles}
set_parameter_range $core MAX_RETRIES 0 15 \
  {Maximum timeout or RNR retries; the retry counter is four bits}
set_parameter_range $core MAX_SEQUENCE_RECOVERIES 0 65535 \
  {Maximum sequence-error recoveries per physical message}
set_parameter_range $core SEQUENCE_RECOVERY_QUIET_CYCLES 1 2147483647 \
  {Quiet interval in aclk cycles before sequence replay starts}
set_parameter_range $core RNR_TIMER_10US_CYCLES 1 2147483647 \
  {Number of aclk cycles in one 10 microsecond RNR timer unit}

# The HDL defaults express the relationship between clock frequency and timer
# cycles for direct RTL instantiation. The Catalog parameters remain editable,
# and the XGUI callback below owns their frequency-dependent defaults.
foreach timer_parameter {ACK_TIMEOUT_CYCLES RNR_TIMER_10US_CYCLES} {
  set hdl_parameter [ipx::get_hdl_parameters $timer_parameter \
    -of_objects $core]
  if {[llength $hdl_parameter] != 1} {
    error "Expected packaged HDL parameter $timer_parameter"
  }
  set_property value_dependency {} $hdl_parameter
}

set gui_groups [ipx::get_file_groups -filter {TYPE == gui} -of_objects $core]
if {[llength $gui_groups] != 1} {
  error "Expected one packaged XGUI file group"
}
set gui_files [ipx::get_files -of_objects $gui_groups]
if {[llength $gui_files] != 1} {
  error "Expected one generated XGUI file"
}
set gui_relative_path [get_property name $gui_files]
set gui_output_file [file join $package_dir $gui_relative_path]
file copy -force $xgui_template $gui_output_file

set documentation_dir [file join $package_dir docs]
file mkdir $documentation_dir
file copy -force $readme_file [file join $documentation_dir README.md]
file copy -force $architecture_file \
  [file join $documentation_dir ARCHITECTURE.md]
set product_guide_group [ipx::add_file_group -type product_guide \
  xilinx_productguide $core]
set_property display_name {RDMA Transport IP Documentation} \
  $product_guide_group
foreach document {README.md ARCHITECTURE.md} {
  set packaged_document [ipx::add_file [file join docs $document] \
    $product_guide_group]
  set_property description "RDMA transport IP $document" $packaged_document
}

foreach busif {S_AXIS_PAYLOAD S_AXIS_RX M_AXIS_TX} {
  if {[llength [ipx::get_bus_interfaces $busif -of_objects $core]] != 1} {
    error "Expected packaged AXI-Stream interface $busif"
  }
  ipx::associate_bus_interfaces -busif $busif -clock aclk $core
}

set clock_interface [ipx::get_bus_interfaces aclk -of_objects $core]
set clock_frequency [ipx::get_bus_parameters FREQ_HZ \
  -of_objects $clock_interface]
if {[llength $clock_frequency] != 1} {
  error "Expected packaged aclk FREQ_HZ parameter"
}
set_property value_resolve_type dependent $clock_frequency
set_property value_dependency \
  {spirit:decode(id('PARAM_VALUE.ACLK_FREQ_HZ'))} $clock_frequency
if {[get_property value_resolve_type $clock_frequency] ne "dependent" ||
    [get_property value_dependency $clock_frequency] ne \
      {spirit:decode(id('PARAM_VALUE.ACLK_FREQ_HZ'))}} {
  error "Failed to bind packaged aclk frequency metadata"
}

if {[llength [ipx::get_ports aresetn -of_objects $core]] != 1} {
  error "Expected active-low packaged reset port aresetn"
}

ipx::check_integrity -quiet $core
ipx::save_core $core
close_project

set component_file [file join $package_dir component.xml]
if {![file exists $component_file]} {
  error "Vivado did not generate $component_file"
}
puts "RDMA_TRANSPORT_IP component=$component_file"
