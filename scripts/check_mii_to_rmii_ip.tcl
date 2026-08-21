# Read-only Vivado IP-catalog check.  No IP is created by this script.
set matches [get_ipdefs -all -quiet -filter {VLNV =~ "*mii_to_rmii*"}]

if {[llength $matches] == 0} {
    puts "MII_TO_RMII_IP_AVAILABLE: NO"
    exit 2
}

puts "MII_TO_RMII_IP_AVAILABLE: YES"
foreach ipdef $matches {
    puts "MII_TO_RMII_IPDEF: [get_property VLNV $ipdef]"
}
