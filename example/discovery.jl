using UPnPClient

# survey the local LAN, there should be a router unless its SSDP is off.
probe_network(; timeout_secs = 7)

println("Opening a port on your router")
igd = find_gateway()
@show igd
println("Router external IP: ", external_ip_address(igd))
add_port_forward(
    igd;
    external_port = 8080,
    description = "my julia server",
    lease_secs = 3600,
)
remove_port_forward(igd; external_port = 8080)
println("Port 8080 has been added, then removed from your router")
