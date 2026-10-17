using UPnP

# survey the local LAN, there should be a router unless its SSDP is off.
ssdpquery(; timeoutsecs = 7)

println("Opening a port on your router")
igd = find_igd()
@show igd
println("Router external IP: ", external_ip(igd))
add_port_mapping(igd; external_port = 8080, description = "my julia server", lease = 3600)
delete_port_mapping(igd; external_port = 8080)
println("Port 8080 has been added, then removed from your router")
