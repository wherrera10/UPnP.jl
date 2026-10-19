# UPnPClient.jl

<img src="https://github.com/wherrera10/UPnPClient.jl/blob/main/docs/src/assets/UPnP-public.png">

A Julia client for **Universal Plug and Play (UPnP)**. Functions that discover devices on your local network, inspect what they offer, and control them.

[![Documentation Status](https://img.shields.io/badge/docs-latest-blue.svg)](https://wherrera10.github.io/UPnPClient.jl/)
[![CI](https://github.com/wherrera10/UPnPClient.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/wherrera10/UPnPClient.jl/actions/workflows/CI.yml)


```julia
using UPnPClient

igd = find_gateway()                          # find your router
external_ip_address(igd)                      # "203.0.113.7"
add_port_forward(igd; external_port = 8080, lease_secs = 3600)
```


## Features

- **SSDP discovery**: send `M-SEARCH` queries and collect replies, with typed search targets (`AllDevices`, `RootDeviceOnly`, `DeviceUUID`, `UPnPURN`, `CustomTarget`).
- **Device and service descriptions**: download and parse a device's XML description into `DeviceNode` and `ServiceEndpoint` objects, including embedded devices, with absolute URLs.
- **SOAP control**: call any action on any service and get the output arguments back; device faults are raised as `SoapFault`.
- **Router helpers**: external IP lookup and port mapping/unmapping on Internet Gateway Devices.

## Installation

You may be able to install the package from the Julia REPL in the usual way with  `]add UPnPClient`,  
or to install from the current master copy:

```julia
using Pkg
Pkg.add(url = "https://github.com/wherrera10/UPnPClient.jl")
```

Requires Julia 1.8 or later (for `chopprefix`), plus [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) and [EzXML.jl](https://github.com/JuliaIO/EzXML.jl), which are installed automatically.

## Usage

### Discover devices

```julia
using UPnPClient

# Everything that answers
for r in collect_replies(AllDevices(); timeout_secs = 5)
    println(r.location, "  ", r.server)
end

# Only a specific kind of device
target = parse(SearchTarget, "urn:schemas-upnp-org:device:MediaRenderer:1")
renderers = collect_replies(target)
```

Each reply is an `SsdpReply` with `.location`, `.usn`, `.server`, `.st` and the full `.headers` dictionary.

### Search targets

Search targets parse from, and print as, the strings used on the wire:

```julia
parse(SearchTarget, "ssdp:all")                                    # AllDevices()
parse(SearchTarget, "upnp:rootdevice")                             # RootDeviceOnly()
parse(SearchTarget, "uuid:2fac1234-31f8-11b4-a222-08002b34c003")   # DeviceUUID(...)
parse(SearchTarget, "urn:schemas-upnp-org:service:RenderingControl:1")
parse(SearchTarget, "roku:ecp")                                    # CustomTarget("roku", "ecp")

make_device_urn("schemas-upnp-org", "ZonePlayer", 1)
string(make_service_urn("schemas-sonos-com", "Queue", 1))   # "urn:schemas-sonos-com:service:Queue:1"
```

Invalid input throws `UrnParseError` or `SearchTargetParseError`; use `tryparse` if you would rather get `nothing`.

### Inspect a device

```julia
dev = load_device(first(renderers))
dev.friendly_name
dev.services                  # Vector{ServiceEndpoint}

svc = find_service(dev, "urn:schemas-upnp-org:service:RenderingControl:1")
svc.control_url
```

`find_service` searches embedded devices too, and a service with a higher version number satisfies a request for a lower one.

### Control a device

```julia
invoke_action(svc, "GetVolume"; InstanceID = 0, Channel = "Master")
# Dict("CurrentVolume" => "25")

invoke_action(svc, "SetVolume"; InstanceID = 0, Channel = "Master", DesiredVolume = 30)
```

Arguments are sent in the order given, since some devices require it. If the device returns a fault you get a `SoapFault` with its numeric `code` and `message`.

### Open a port on your router

```julia
igd = find_gateway()
external_ip_address(igd)

add_port_forward(igd;
    external_port   = 8080,
    internal_port   = 8080,            # defaults to external_port
    internal_client = "192.168.1.50",   # defaults to this machine's primary address
    protocol        = "TCP",
    description     = "my julia server",
    lease_secs      = 3600)            # seconds; 0 = permanent (some routers reject this)

remove_port_forward(igd; external_port = 8080)
```

### Simple LAN UPnP / SSDP scanner with query function

A simple SSDP query scanner is still available.  
It prints all replies if invoked without an initial argument (the usual usage),  
or returns the first one matching a first argument string or case-insensitive regex:

```julia
probe_network("roku"; target = RootDeviceOnly(), timeout_secs = 30)
```

## Troubleshooting

- **No devices found.** UPnP uses UDP multicast, which is often blocked by VPNs, guest Wi-Fi, and some firewalls. Try disabling the VPN, and check that your firewall allows UDP replies. Containers and VMs usually need host or bridged networking.
- **Port mapping fails with error 725 (`OnlyPermanentLeasesSupported`).** Some routers reject a lease of 0, others reject any non-zero lease. Try the other.
- **Port mapping fails with error 718 (`ConflictInMappingEntry`).** That external port is already mapped. Delete the old mapping or choose another port.
- **Wrong internal address.** On machines with several network interfaces (VPNs, Docker, VMs), `getipaddr()` may pick the wrong one. Pass `internal_client` explicitly.
- **Router has UPnP turned off.** SSDP is disabled by default on many routers for security reasons after a network flooding attack using SSDP was found in 2014. See the note below.

## Security note

UPnP has no authentication. Any device or program on your local network can ask your router to open ports, and a number of consumer routers have had serious UPnP vulnerabilities. You should only create the port mappings you need, use leases that expire, and close open ports when not in common use. Consider disabling UPnP / SSDP on your router when not using it, then re-enabling it when needed, as when using this module. Keep SSDP traffic and UPnP queries within the local LAN.

## Testing setup after installation

From REPL:
```
julia> ]test UPnPClient
```

Default tests run offline against sample XML. To include a live network test:

```
julia> ENV["UPNP_NETWORK_TESTS"] = "1"

julia> ]test UPnPClient
```

## Contributing

The package was inspired by a simple need to find a single custom device type on the local network, and so the author's own applications have been limited. Suggestions for features and patches for new or old functions are welcome. For example, as of v0.1 we lack features such as eventing (GENA subscriptions), passive listening for `NOTIFY` announcements, and IPv6 multicast.

## See also

Full UPnP documentation is available elsewhere. In particular, the [UPnP Device Architecture specification](https://openconnectivity.org/developer/specifications/upnp-resources/upnp/) is available from the Open Connectivity Foundation.
```
