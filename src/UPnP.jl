""" Universal Plug and Play (UPnP) helpers: SSDP search targets, URNs, and discovery """
module UPnP

export SearchTarget, All, RootDevice, UUID, URN, Custom,
       device_urn, service_urn, domain_name, typ, version, kind,
       ParseURNError, ParseSearchTargetError,
       SSDPResponse, parse_response,
       ssdpquery, discover,
       Service, Device, fetch_device, parse_device, find_service,
       UPnPError, call_action,
       find_igd, external_ip, add_port_mapping, delete_port_mapping

using Sockets
using HTTP
using EzXML

# Network related constants
const MULTICAST = ip"239.255.255.250"
const SERVERPORT = 1900

""" Errors for URN and search target parsing """
struct ParseURNError <: Exception
    input::String
end
Base.showerror(io::IO, e::ParseURNError) =
    print(io, "ParseURNError: invalid URN: \"", e.input, "\"")

""" Errors for search target parsing """
struct ParseSearchTargetError <: Exception
    input::String
    cause::Union{Nothing,ParseURNError}
end
ParseSearchTargetError(input) = ParseSearchTargetError(input, nothing)
Base.showerror(io::IO, e::ParseSearchTargetError) =
    print(io, "ParseSearchTargetError: invalid search target: \"", e.input, "\"")


"""
    Struct to specify what SSDP control points to search for. Subtypes:
    `All`, `RootDevice`, `UUID`, `URN`, `Custom`.
"""
abstract type SearchTarget end

""" Search for all devices and services (`ssdp:all`). """
struct All <: SearchTarget end

""" Search for root devices only (`upnp:rootdevice`). """
struct RootDevice <: SearchTarget end

""" Unique identifier for a device (`uuid:<id>`). """
struct UUID <: SearchTarget
    id::String
end

"""
    UPnP Uniform Resource Name, e.g. `urn:schemas-upnp-org:service:RenderingControl:1`.
    `kind` is either `:device` or `:service`.
"""
struct URN <: SearchTarget
    kind::Symbol
    domain::String
    typ::String
    version::UInt32

    """ 
        URN(kind::Symbol, domain::AbstractString, typ::AbstractString, version::Integer)

    Constructor for URN. 
    """
    function URN(kind::Symbol, domain::AbstractString, typ::AbstractString, version::Integer)
        kind in (:device, :service) ||
            throw(ArgumentError("URN kind must be :device or :service, got :$kind"))
        new(kind, String(domain), String(typ), UInt32(version))
    end
end

""" Custom search target, e.g. `roku:ecp` """
struct Custom <: SearchTarget
    key::String
    value::String
end

""" Constructors mirroring URN::device or URN::service """
device_urn(domain, typ, version) = URN(:device, domain, typ, version)
service_urn(domain, typ, version) = URN(:service, domain, typ, version)

""" Extracts the `schemas-upnp-org` part of `urn:schemas-upnp-org:service:RenderingControl:1`."""
domain_name(u::URN) = u.domain

""" Extracts the `RenderingControl` part of `urn:schemas-upnp-org:service:RenderingControl:1`."""
typ(u::URN) = u.typ

""" Extracts the `1` part of `urn:schemas-upnp-org:service:RenderingControl:1`."""
version(u::URN) = Int(u.version)

""" Extracts the `:device` vs. `:service` part of the URN. """
kind(u::URN) = u.kind

# Equality / hashing / ordering (Rust: Eq, PartialEq, Ord; Device < Service)
Base.:(==)(a::URN, b::URN) =
    a.kind == b.kind && a.domain == b.domain && a.typ == b.typ && a.version == b.version
Base.hash(u::URN, h::UInt) = hash((u.kind, u.domain, u.typ, u.version), hash(:URN, h))
_urnkey(u::URN) = (u.kind === :service, u.domain, u.typ, u.version)
Base.isless(a::URN, b::URN) = isless(_urnkey(a), _urnkey(b))

Base.:(==)(a::UUID, b::UUID) = a.id == b.id
Base.hash(a::UUID, h::UInt) = hash(a.id, hash(:UUID, h))
Base.:(==)(a::Custom, b::Custom) = a.key == b.key && a.value == b.value
Base.hash(a::Custom, h::UInt) = hash((a.key, a.value), hash(:Custom, h))
Base.:(==)(::All, ::All) = true
Base.:(==)(::RootDevice, ::RootDevice) = true
Base.hash(::All, h::UInt) = hash(:All, h)
Base.hash(::RootDevice, h::UInt) = hash(:RootDevice, h)

# Display: Base.string(x) gives the wire format used in the ST header
Base.show(io::IO, ::All) = print(io, "ssdp:all")
Base.show(io::IO, ::RootDevice) = print(io, "upnp:rootdevice")
Base.show(io::IO, u::UUID) = print(io, "uuid:", u.id)
Base.show(io::IO, u::URN) = print(io, "urn:", u.domain, ":", u.kind, ":", u.typ, ":", u.version)
Base.show(io::IO, c::Custom) = print(io, c.key, ":", c.value)

"""
    parse(URN, str)

Parse e.g. `urn:schemas-upnp-org:service:RenderingControl:1`.
Throws `ParseURNError` on failure.
"""
function Base.parse(::Type{URN}, str::AbstractString)
    parts = split(str, ':')
    length(parts) == 5 || throw(ParseURNError(str))
    parts[1] == "urn" || throw(ParseURNError(str))

    domain, urn_type, name, ver = parts[2], parts[3], parts[4], parts[5]
    v = tryparse(UInt32, ver)
    v === nothing && throw(ParseURNError(str))

    lt = lowercase(urn_type)
    lt == "service" && return URN(:service, domain, name, v)
    lt == "device"  && return URN(:device, domain, name, v)
    throw(ParseURNError(str))
end

"""
    parse(SearchTarget, str)

Parse any SSDP search target string. Throws `ParseSearchTargetError`.
"""
function Base.parse(::Type{SearchTarget}, s::AbstractString)
    s == "ssdp:all" && return All()
    s == "upnp:rootdevice" && return RootDevice()
    startswith(s, "uuid") && return UUID(String(chopprefix(s, "uuid:")))
    if startswith(s, "urn")
        try
            return parse(URN, s)
        catch e
            e isa ParseURNError && throw(ParseSearchTargetError(String(s), e))
            rethrow()
        end
    end
    parts = split(s, ':')
    length(parts) == 2 || throw(ParseSearchTargetError(String(s)))
    return Custom(parts[1], parts[2])
end

Base.tryparse(::Type{SearchTarget}, s::AbstractString) =
    try parse(SearchTarget, s) catch e
        e isa ParseSearchTargetError ? nothing : rethrow()
    end
Base.tryparse(::Type{URN}, s::AbstractString) =
    try parse(URN, s) catch e
        e isa ParseURNError ? nothing : rethrow()
    end

""" Struct for a parsed SSDP reply. `headers` keys are upper-cased. """
struct SSDPResponse
    status::String
    headers::Dict{String,String}
    raw::String
end

Base.getproperty(r::SSDPResponse, s::Symbol) =
    s in (:status, :headers, :raw) ? getfield(r, s) :
    s === :location ? get(getfield(r, :headers), "LOCATION", nothing) :
    s === :usn      ? get(getfield(r, :headers), "USN", nothing) :
    s === :server   ? get(getfield(r, :headers), "SERVER", nothing) :
    s === :st       ? _parse_st(get(getfield(r, :headers), "ST", nothing)) :
    error("SSDPResponse has no property $s")

_parse_st(::Nothing) = nothing
_parse_st(s) = tryparse(SearchTarget, s)

"""
    parse_response(raw::AbstractString)

Parse an SSDP response from a raw string. 
"""
function parse_response(raw::AbstractString)
    lines = split(raw, r"\r?\n")
    status = isempty(lines) ? "" : String(strip(first(lines)))
    headers = Dict{String,String}()
    for l in lines[2:end]
        i = findfirst(':', l)
        i === nothing && continue
        headers[uppercase(String(strip(l[1:i-1])))] = String(strip(l[i+1:end]))
    end
    SSDPResponse(status, headers, String(raw))
end

""" 
    msearch(st::SearchTarget; mx::Integer = 10)

Construct an M-SEARCH request. 
"""
msearch(st::SearchTarget; mx::Integer = 10) =
    "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n" *
    "ST: $(string(st))\r\nMX: $mx\r\n\r\n"

"""
    ssdpquery(matchtxt = ""; st = All(), timeoutsecs = 10 * 60)

Query the local network for devices responding with SSDP.

`matchtxt` is optional text (regex, case-insensitive) to match, such as "Roku".
`st` is the `SearchTarget` to ask for, e.g. `RootDevice()` or
`parse(SearchTarget, "urn:schemas-upnp-org:device:ZonePlayer:1")`.

If `matchtxt` has a capture, the captures are returned, otherwise the whole
matching reply. With no `matchtxt`, all replies are printed until timeout
(default 10 minutes) or Control-C. Returns `nothing` on timeout.
"""
function ssdpquery(matchtxt = ""; st::SearchTarget = All(), timeoutsecs = 10 * 60)
    # MX is how long in s devices may randomly delay their reply, so keep 
    # timeoutsecs well over the MX value timeout to avoid missing responses.
    request = msearch(st; mx = clamp(floor(Int, timeoutsecs) - 1, 1, 5))
    endtime = time() + timeoutsecs
    try
        while time() < endtime
            udpsock = UDPSocket()
            timed_out = Ref(false)
            # Force recv() to give up once the time budget is used up.
            timer = Timer(max(0.0, endtime - time())) do _
                timed_out[] = true
                close(udpsock)
            end
            try
                # A fresh UDPSocket must be bound before it counts as open.
                bind(udpsock, ip"0.0.0.0", 0) || error("Could not bind a UDP socket")
                send(udpsock, MULTICAST, SERVERPORT, request)
                reply = String(recv(udpsock))
                if matchtxt == ""
                    println("Received reply:\r\n$reply")
                else
                    regex = Regex(matchtxt, "is")
                    if (mat = match(regex, reply)) !== nothing
                        length(mat.captures) > 0 && return mat.captures
                        return reply
                    end
                end
            catch err
                err isa InterruptException && rethrow()
                timed_out[] || rethrow()   # only the timeout closing the socket is expected
            finally
                close(timer)
                close(udpsock)
            end
            sleep(3)
        end
    catch y
        println("Caught error: $y")
        return ""
    end
    return nothing
end

"""
    discover(st = All(); timeoutsecs = 5, mx = 3)::Vector{SSDPResponse}

Send one M-SEARCH for `st` and collect every reply received within
`timeoutsecs`. Duplicate USNs are dropped. Replies are parsed into
`SSDPResponse` objects (`.location`, `.usn`, `.server`, `.st`, `.headers`).
"""
function discover(st::SearchTarget = All(); timeoutsecs = 5, mx = 3)
    udpsock = UDPSocket()
    timed_out = Ref(false)
    timer = Timer(timeoutsecs) do _
        timed_out[] = true
        close(udpsock)          # makes the blocked recv() throw, ending the loop
    end
    found = SSDPResponse[]
    seen = Set{String}()
    try
        # A fresh UDPSocket is not "open" until it is bound, so bind to an
        # ephemeral port before sending or receiving.
        bind(udpsock, ip"0.0.0.0", 0) || error("Could not bind a UDP socket")
        send(udpsock, MULTICAST, SERVERPORT, msearch(st; mx = mx))
        while true
            raw = String(recv(udpsock))
            r = parse_response(raw)
            key = something(r.usn, raw)
            key in seen && continue
            push!(seen, key)
            push!(found, r)
        end
    catch err
        err isa InterruptException && rethrow() # user control-C
        # The socket being closed by the timer is the normal way out; anything else is an error.
        timed_out[] || rethrow()
    finally
        close(timer)
        close(udpsock) # safe on an unbound socket, unlike isopen()
    end
    return found
end


""" 
    Struct for a UPnP service as listed in a device description. 
    Note that all such URLs are absolute.
"""
struct Service
    service_type::String # e.g. "urn:schemas-upnp-org:service:RenderingControl:1"
    service_id::String
    scpd_url::String # Service description (actions or similar state variables)
    control_url::String # SOAP endpoint
    event_sub_url::String # GENA subscription endpoint
end

""" Struct to represent a UPnP device. Embedded devices are in `devices`. """
struct Device
    device_type::String
    friendly_name::String
    manufacturer::String
    model_name::String
    udn::String
    location::String
    services::Vector{Service}
    devices::Vector{Device}
end

Base.show(io::IO, s::Service) = print(io, "Service(", s.service_type, ")")
Base.show(io::IO, d::Device) =
    print(io, "Device(\"", d.friendly_name, "\", ", d.device_type, ", ",
          length(d.services), " services, ", length(d.devices), " embedded)")

# XML helpers (namespace-agnostic: we match on local element names)
_kids(node, name) = [e for e in eachelement(node) if nodename(e) == name]
function _text(node, name)
    k = _kids(node, name)
    isempty(k) ? "" : String(strip(nodecontent(first(k))))
end
_abs(base, ref) = isempty(ref) ? "" : string(HTTP.URIs.resolvereference(base, ref))

function _parse_device(node, base, location)
    services = Service[]
    for sl in _kids(node, "serviceList"), s in _kids(sl, "service")
        push!(services, Service(
            _text(s, "serviceType"),
            _text(s, "serviceId"),
            _abs(base, _text(s, "SCPDURL")),
            _abs(base, _text(s, "controlURL")),
            _abs(base, _text(s, "eventSubURL"))))
    end
    subs = Device[]
    for dl in _kids(node, "deviceList"), d in _kids(dl, "device")
        push!(subs, _parse_device(d, base, location))
    end
    Device(_text(node, "deviceType"), _text(node, "friendlyName"),
           _text(node, "manufacturer"), _text(node, "modelName"),
           _text(node, "UDN"), location, services, subs)
end

"""
    fetch_device(location; timeout = 5)::Device
    fetch_device(response::SSDPResponse; timeout = 5)::Device

Download and parse a device description from its `LOCATION` URL.
"""
function fetch_device(location::AbstractString; timeout = 5)
    resp = HTTP.get(location; readtimeout = timeout, connect_timeout = timeout)
    parse_device(String(resp.body), location)
end

"""
    parse_device(xml, location)::Device

Parse a UPnP device description document. `location` is the URL it came from,
used to resolve relative service URLs when the document has no `URLBase`.
"""
function parse_device(xml::AbstractString, location::AbstractString)
    r = root(parsexml(xml))
    devs = _kids(r, "device")
    isempty(devs) && error("No <device> element found in description at $location")
    urlbase = _text(r, "URLBase")
    base = isempty(urlbase) ? String(location) : urlbase
    _parse_device(first(devs), base, String(location))
end

function fetch_device(r::SSDPResponse; kw...)
    r.location === nothing && error("SSDP response has no LOCATION header")
    fetch_device(r.location; kw...)
end

"""
    find_service(device, target)::Union{Service,Nothing}

Search `device` and its embedded devices for a service. `target` may be a
service `URN` or a string. The service must match domain and type, and its
version must be at least the requested version.
"""
function find_service(dev::Device, target::URN)
    for s in dev.services
        u = tryparse(URN, s.service_type)
        u === nothing && continue
        if u.kind === target.kind && u.domain == target.domain &&
           u.typ == target.typ && u.version >= target.version
            return s
        end
    end
    for d in dev.devices
        s = find_service(d, target)
        s === nothing || return s
    end
    return nothing
end
find_service(dev::Device, target::AbstractString) = find_service(dev, parse(URN, target))


""" Exception type for UPnP errors returned by a device in a SOAP fault. """
struct UPnPError <: Exception
    code::Int
    description::String
end
Base.showerror(io::IO, e::UPnPError) =
    print(io, "UPnPError ", e.code, ": ", e.description)

_xmlescape(s) = replace(string(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;",
                        '"' => "&quot;", '\'' => "&apos;")

function _envelope(service_type, action, args)
    body = join(("<$k>$(_xmlescape(v))</$k>" for (k, v) in pairs(args)))
    """<?xml version="1.0"?>""" *
    """<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" """ *
    """s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>""" *
    """<u:$action xmlns:u="$service_type">$body</u:$action></s:Body></s:Envelope>"""
end

"""
    call_action(service, action; timeout = 5, args...) -> Dict{String,String}

Invoke a SOAP action on `service`. Arguments are keywords and are sent in the
order given (some devices care):

    call_action(svc, "SetVolume"; InstanceID = 0, Channel = "Master", DesiredVolume = 30)

Returns the output arguments as a dictionary. Throws `UPnPError` if the device
reports a fault.
"""
function call_action(service::Service, action::AbstractString; timeout = 5, args...)
    headers = ["Content-Type" => "text/xml; charset=\"utf-8\"",
               "SOAPACTION" => "\"$(service.service_type)#$action\""]
    resp = HTTP.post(service.control_url, headers,
                     _envelope(service.service_type, action, args);
                     status_exception = false,
                     request_timeout = timeout, connect_timeout = timeout)
    _parse_soap_response(String(resp.body), resp.status, service.control_url)
end

# Parse a SOAP reply body into output arguments, or throw UPnPError on a fault.
function _parse_soap_response(body::AbstractString, status::Integer, url::AbstractString = "")
    doc = try
        parsexml(body)
    catch
        error("Device returned an unparseable response (HTTP $status)")
    end
    bodies = findall("//*[local-name()='Body']", doc)
    isempty(bodies) && error("SOAP response has no Body (HTTP $(status))")
    payload = first(eachelement(first(bodies)))

    if nodename(payload) == "Fault"
        code, desc = 0, "unknown error"
        for e in findall(".//*[local-name()='UPnPError']", payload)
            code = something(tryparse(Int, _text(e, "errorCode")), 0)
            desc = _text(e, "errorDescription")
        end
        throw(UPnPError(code, desc))
    end
    status >= 400 && error("HTTP $status from $url")
    Dict{String,String}(nodename(e) => String(strip(nodecontent(e)))
                        for e in eachelement(payload))
end

const IGD_TARGET = device_urn("schemas-upnp-org", "InternetGatewayDevice", 1)
const WAN_SERVICES = (service_urn("schemas-upnp-org", "WANIPConnection", 1),
                      service_urn("schemas-upnp-org", "WANPPPConnection", 1))

"""
    find_igd(; timeoutsecs = 5)

Discover the first Internet Gateway Device (your router) and fetch its description.
"""
function find_igd(; timeoutsecs = 5)
    for r in discover(IGD_TARGET; timeoutsecs = timeoutsecs)
        try
            return fetch_device(r)
        catch
            continue
        end
    end
    error("No Internet Gateway Device found on the network")
end

function _wan_service(igd::Device)
    for t in WAN_SERVICES
        s = find_service(igd, t)
        s === nothing || return s
    end
    error("Gateway \"$(igd.friendly_name)\" has no WANIPConnection or WANPPPConnection service")
end

""" Ask the router for its external (WAN) IP address. """
external_ip(igd::Device = find_igd()) =
    call_action(_wan_service(igd), "GetExternalIPAddress")["NewExternalIPAddress"]

"""
    add_port_mapping(igd; external_port, internal_port = external_port,
                     internal_client = string(getipaddr()), protocol = "TCP",
                     description = "PlugAndPlay.jl", lease = 0)

Forward `external_port` on the router to `internal_client:internal_port`.
`lease` is in seconds; 0 means permanent (some routers reject this).
"""
function add_port_mapping(igd::Device; external_port::Integer,
                          internal_port::Integer = external_port,
                          internal_client::AbstractString = string(getipaddr()),
                          protocol::AbstractString = "TCP",
                          description::AbstractString = "PlugAndPlay.jl",
                          lease::Integer = 0)
    call_action(_wan_service(igd), "AddPortMapping";
                NewRemoteHost = "",
                NewExternalPort = external_port,
                NewProtocol = uppercase(protocol),
                NewInternalPort = internal_port,
                NewInternalClient = internal_client,
                NewEnabled = 1,
                NewPortMappingDescription = description,
                NewLeaseDuration = lease)
    nothing
end

""" Remove a port mapping previously created on the router. """
function delete_port_mapping(igd::Device; external_port::Integer, protocol::AbstractString = "TCP")
    call_action(_wan_service(igd), "DeletePortMapping";
                NewRemoteHost = "",
                NewExternalPort = external_port,
                NewProtocol = uppercase(protocol))
    nothing
end


end # module UPnP
