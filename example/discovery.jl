using UPnP

# Control a device found by discovery
r   = first(discover(parse(SearchTarget, "urn:schemas-upnp-org:device:MediaRenderer:1")))
dev = fetch_device(r)
svc = find_service(dev, "urn:schemas-upnp-org:service:RenderingControl:1")
call_action(svc, "GetVolume"; InstanceID = 0, Channel = "Master")

# Open a port on your router
igd = find_igd()
println(external_ip(igd))
add_port_mapping(igd; external_port = 8080, description = "my julia server", lease = 3600)
delete_port_mapping(igd; external_port = 8080)
