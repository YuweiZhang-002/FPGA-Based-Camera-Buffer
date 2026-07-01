# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "CAM_ID" -parent ${Page_0}
  ipgui::add_param $IPINST -name "num_lines" -parent ${Page_0}
  ipgui::add_param $IPINST -name "num_pixel" -parent ${Page_0}


}

proc update_PARAM_VALUE.CAM_ID { PARAM_VALUE.CAM_ID } {
	# Procedure called to update CAM_ID when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.CAM_ID { PARAM_VALUE.CAM_ID } {
	# Procedure called to validate CAM_ID
	return true
}

proc update_PARAM_VALUE.num_lines { PARAM_VALUE.num_lines } {
	# Procedure called to update num_lines when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.num_lines { PARAM_VALUE.num_lines } {
	# Procedure called to validate num_lines
	return true
}

proc update_PARAM_VALUE.num_pixel { PARAM_VALUE.num_pixel } {
	# Procedure called to update num_pixel when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.num_pixel { PARAM_VALUE.num_pixel } {
	# Procedure called to validate num_pixel
	return true
}


proc update_MODELPARAM_VALUE.num_pixel { MODELPARAM_VALUE.num_pixel PARAM_VALUE.num_pixel } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.num_pixel}] ${MODELPARAM_VALUE.num_pixel}
}

proc update_MODELPARAM_VALUE.num_lines { MODELPARAM_VALUE.num_lines PARAM_VALUE.num_lines } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.num_lines}] ${MODELPARAM_VALUE.num_lines}
}

proc update_MODELPARAM_VALUE.CAM_ID { MODELPARAM_VALUE.CAM_ID PARAM_VALUE.CAM_ID } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.CAM_ID}] ${MODELPARAM_VALUE.CAM_ID}
}

