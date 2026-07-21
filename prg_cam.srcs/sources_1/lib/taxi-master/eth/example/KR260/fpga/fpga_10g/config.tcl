# SPDX-License-Identifier: MIT
#
# Copyright (c) 2025 FPGA Ninja, LLC
#
# Authors:
# - Alex Forencich
#

set params [dict create]

# SFP+ rate
# 0 for 1G, 1 for 10G
dict set params SFP_RATE "1"

# apply parameters to top-level
set param_list {}
dict for {name value} $params {
    lappend param_list $name=$value
}

set_property generic $param_list [get_filesets sources_1]
