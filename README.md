# UPnP.jl

<img src="https://github.com/wherrera10/UPnP.jl/blob/main/docs/src/assets/upnp-trademark-by-open-connectivity.png">

A Julia client for **Universal Plug and Play (UPnP)**. Discover devices on your local network, inspect what they offer, and control them.

```julia
using UPnP

igd = find_igd()                          # find your router
external_ip(igd)                          # "203.0.113.7"
add_port_mapping(igd; external_port = 8080, lease = 3600)
```


## Features

- **SSDP discovery**: send `M-SEARCH` queries and collect replies, with typed search targets (`All`, `RootDevice`, `UUID`, `URN`, `Custom`).
- **Device and service descriptions**: download and parse a device's XML description into `Device` and `Service` objects, including embedded devices, with absolute URLs.
- **SOAP control**: call any action on any service and get the output arguments back; device faults are raised as `UPnPError`.
- **Router helpers**: external IP lookup and port mapping/unmapping on Internet Gateway Devices.

## Installation

You may be able to install the package from the Julia REPL in the usual way with  `]add UPnP`,  
or to install from the current master copy:

```julia
using Pkg
Pkg.add(url = "https://github.com/wherrera10/UPnP.jl")
```

Requires Julia 1.8 or later (for `chopprefix`), plus [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) and [EzXML.jl](https://github.com/JuliaIO/EzXML.jl), which are installed automatically.

## Usage

### Discover devices

```julia
using UPnP

# Everything that answers
for r in discover(All(); timeoutsecs = 5)
    println(r.location, "  ", r.server)
end

# Only a specific kind of device
target = parse(SearchTarget, "urn:schemas-upnp-org:device:MediaRenderer:1")
renderers = discover(target)
```

Each reply is an `SSDPResponse` with `.location`, `.usn`, `.server`, `.st` and the full `.headers` dictionary.

### Search targets

Search targets parse from, and print as, the strings used on the wire:

```julia
parse(SearchTarget, "ssdp:all")                                    # All()
parse(SearchTarget, "upnp:rootdevice")                             # RootDevice()
parse(SearchTarget, "uuid:2fac1234-31f8-11b4-a222-08002b34c003")   # UUID(...)
parse(SearchTarget, "urn:schemas-upnp-org:service:RenderingControl:1")
parse(SearchTarget, "roku:ecp")                                    # Custom("roku", "ecp")

device_urn("schemas-upnp-org", "ZonePlayer", 1)
string(service_urn("schemas-sonos-com", "Queue", 1))   # "urn:schemas-sonos-com:service:Queue:1"
```

Invalid input throws `ParseURNError` or `ParseSearchTargetError`; use `tryparse` if you would rather get `nothing`.

### Inspect a device

```julia
dev = fetch_device(first(renderers))
dev.friendly_name
dev.services                  # Vector{Service}

svc = find_service(dev, "urn:schemas-upnp-org:service:RenderingControl:1")
svc.control_url
```

`find_service` searches embedded devices too, and a service with a higher version number satisfies a request for a lower one.

### Control a device

```julia
call_action(svc, "GetVolume"; InstanceID = 0, Channel = "Master")
# Dict("CurrentVolume" => "25")

call_action(svc, "SetVolume"; InstanceID = 0, Channel = "Master", DesiredVolume = 30)
```

Arguments are sent in the order given, since some devices require it. If the device returns a fault you get a `UPnPError` with its numeric `code` and `description`.

### Open a port on your router

```julia
igd = find_igd()
external_ip(igd)

add_port_mapping(igd;
    external_port   = 8080,
    internal_port   = 8080,          # defaults to external_port
    internal_client = "192.168.1.50",  # defaults to this machine's primary address
    protocol        = "TCP",
    description     = "my julia server",
    lease           = 3600)          # seconds; 0 = permanent (some routers reject this)

delete_port_mapping(igd; external_port = 8080)
```

### Simple LAN UPnP / SSDP scanner with simple query function

A simple SSDP query scanner (from a prior SSCPCLient module) is still available. 
It prints all replies if invoked without an initial argument (the usual usage), 
or returns the first one matching a first argument string or case-insensitive regex:

```julia
ssdpquery("roku"; st = RootDevice(), timeoutsecs = 30)
```

## Troubleshooting

- **No devices found.** UPnP uses UDP multicast, which is often blocked by VPNs, guest Wi-Fi, and some firewalls. Try disabling the VPN, and check that your firewall allows UDP replies. Containers and VMs usually need host or bridged networking.
- **Port mapping fails with error 725 (`OnlyPermanentLeasesSupported`).** Some routers reject a lease of 0, others reject any non-zero lease. Try the other.
- **Port mapping fails with error 718 (`ConflictInMappingEntry`).** That external port is already mapped. Delete the old mapping or choose another port.
- **Wrong internal address.** On machines with several network interfaces (VPNs, Docker, VMs), `getipaddr()` may pick the wrong one. Pass `internal_client` explicitly.
- **Router has UPnP turned off.** SSDP is disabled by default on many routers for security reasons, 
after an network flooding attack using SSDP was found in 2014. See the note below.

## Security note

UPnP has no authentication. Any device or program on your local network can ask your router to open ports, and a number of consumer routers have had serious UPnP vulnerabilities. You should Only create the port mappings you need, use leases that expire, and close open ports when not in common use. Consider disabling UPnP on your router when not using itm then re-enabling it when using this module.  Keep your UPnP queries within the local LAN.

## Testing setup after installation

From REPL:
```
julia> ]test UPnP
```

Default tests run offline against sample XML. To include a live network test:

```
julia> ENV["UPNP_NETWORK_TESTS"] = "1"

julia> ]test UPnP
```

## Contributing

The package was inspired by a simple need to find a single custom device type on the local network, and so the author's own applications have been limited. Suggestions for features and patches for new or old functions are welcome. For example, as of v0.1 we lack features such as eventing (GENA subscriptions), passive listening for `NOTIFY` announcements, and IPv6 multicast.

## See also

Full UPnP documentation is available elsewhere. In particular, the [UPnP Device Architecture specification](https://openconnectivity.org/developer/specifications/upnp-resources/upnp/) is available from the Open Connectivity Foundation.
