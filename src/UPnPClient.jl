"""
UPnP discovery and control helpers (SSDP search targets, device descriptions, SOAP actions).
"""
module UPnPClient

export
    SearchTarget, AllDevices, RootDeviceOnly, DeviceUUID, UPnPURN, CustomTarget,
    make_device_urn, make_service_urn, urn_domain, urn_type, urn_version, urn_kind,
    UrnParseError, SearchTargetParseError,
    SsdpReply, parse_ssdp_reply,
    probe_network, collect_replies,
    ServiceEndpoint, DeviceNode, load_device, parse_device_xml, find_service,
    SoapFault, invoke_action,
    find_gateway, external_ip_address, add_port_forward, remove_port_forward

using Sockets
using HTTP
using EzXML

# Multicast endpoint used by SSDP
const SSDP_MULTICAST = ip"239.255.255.250"
const SSDP_PORT      = 1900

""" Raised when a URN string cannot be decoded. """
struct UrnParseError <: Exception
    source::String
end
Base.showerror(io::IO, e::UrnParseError) =
    print(io, "UrnParseError: cannot decode \"", e.source, "\"")

""" Raised when an SSDP search-target string cannot be decoded. """
struct SearchTargetParseError <: Exception
    source::String
    nested::Union{Nothing,UrnParseError}
end
SearchTargetParseError(source) = SearchTargetParseError(source, nothing)
Base.showerror(io::IO, e::SearchTargetParseError) =
    print(io, "SearchTargetParseError: cannot decode \"", e.source, "\"")


""" Abstract specification of what an SSDP control point should look for. """
abstract type SearchTarget end

""" Match every device and service (`ssdp:all`). """
struct AllDevices <: SearchTarget end

""" Match only root devices (`upnp:rootdevice`). """
struct RootDeviceOnly <: SearchTarget end

""" Match a concrete device by its unique identifier (`uuid:…`). """
struct DeviceUUID <: SearchTarget
    value::String
end

"""
    Uniform Resource Name of the form `urn:…:device|service:…:N`.
    `kind` is either `:device` or `:service`.
"""
struct UPnPURN <: SearchTarget
    kind::Symbol
    domain::String
    name::String
    ver::UInt32

    function UPnPURN(kind::Symbol, domain::AbstractString, name::AbstractString, ver::Integer)
        kind in (:device, :service) ||
            throw(ArgumentError("kind must be :device or :service, got :$kind"))
        new(kind, String(domain), String(name), UInt32(ver))
    end
end

""" Arbitrary key/value search target (e.g. `roku:ecp`). """
struct CustomTarget <: SearchTarget
    key::String
    val::String
end

make_device_urn(domain, name, ver)  = UPnPURN(:device,  domain, name, ver)
make_service_urn(domain, name, ver) = UPnPURN(:service, domain, name, ver)

urn_domain(u::UPnPURN)  = u.domain
urn_type(u::UPnPURN)    = u.name
urn_version(u::UPnPURN) = Int(u.ver)
urn_kind(u::UPnPURN)    = u.kind

# Equality / hashing / ordering
Base.:(==)(a::UPnPURN, b::UPnPURN) =
    a.kind == b.kind && a.domain == b.domain && a.name == b.name && a.ver == b.ver
Base.hash(u::UPnPURN, h::UInt) = hash((u.kind, u.domain, u.name, u.ver), hash(:UPnPURN, h))
_order_key(u::UPnPURN) = (u.kind === :service, u.domain, u.name, u.ver)
Base.isless(a::UPnPURN, b::UPnPURN) = isless(_order_key(a), _order_key(b))

Base.:(==)(a::DeviceUUID, b::DeviceUUID) = a.value == b.value
Base.hash(a::DeviceUUID, h::UInt) = hash(a.value, hash(:DeviceUUID, h))
Base.:(==)(a::CustomTarget, b::CustomTarget) = a.key == b.key && a.val == b.val
Base.hash(a::CustomTarget, h::UInt) = hash((a.key, a.val), hash(:CustomTarget, h))
Base.:(==)(::AllDevices, ::AllDevices) = true
Base.:(==)(::RootDeviceOnly, ::RootDeviceOnly) = true
Base.hash(::AllDevices, h::UInt) = hash(:AllDevices, h)
Base.hash(::RootDeviceOnly, h::UInt) = hash(:RootDeviceOnly, h)

# Wire-format representation used in the ST header
Base.show(io::IO, ::AllDevices)     = print(io, "ssdp:all")
Base.show(io::IO, ::RootDeviceOnly) = print(io, "upnp:rootdevice")
Base.show(io::IO, u::DeviceUUID)    = print(io, "uuid:", u.value)
Base.show(io::IO, u::UPnPURN)       = print(io, "urn:", u.domain, ":", u.kind, ":", u.name, ":", u.ver)
Base.show(io::IO, c::CustomTarget)  = print(io, c.key, ":", c.val)

"""
    parse(UPnPURN, str)

Decode a string such as `urn:schemas-upnp-org:service:RenderingControl:1`.
Throws `UrnParseError` on failure.
"""
function Base.parse(::Type{UPnPURN}, str::AbstractString)
    parts = split(str, ':')
    length(parts) == 5 || throw(UrnParseError(str))
    parts[1] == "urn" || throw(UrnParseError(str))

    domain, kind_str, name, ver_str = parts[2], parts[3], parts[4], parts[5]
    ver = tryparse(UInt32, ver_str)
    ver === nothing && throw(UrnParseError(str))

    k = lowercase(kind_str)
    k == "service" && return UPnPURN(:service, domain, name, ver)
    k == "device"  && return UPnPURN(:device,  domain, name, ver)
    throw(UrnParseError(str))
end

"""
    parse(SearchTarget, str)

Decode any legal SSDP search-target string. Throws `SearchTargetParseError`.
"""
function Base.parse(::Type{SearchTarget}, s::AbstractString)
    s == "ssdp:all" && return AllDevices()
    s == "upnp:rootdevice" && return RootDeviceOnly()
    if startswith(s, "uuid:")
        value = String(chopprefix(s, "uuid:"))
        isempty(value) && throw(SearchTargetParseError(String(s)))
        return DeviceUUID(value)
    end
    if startswith(s, "urn")
        try
            return parse(UPnPURN, s)
        catch e
            e isa UrnParseError && throw(SearchTargetParseError(String(s), e))
            rethrow()
        end
    end
    parts = split(s, ':')
    length(parts) == 2 || throw(SearchTargetParseError(String(s)))
    return CustomTarget(parts[1], parts[2])
end

Base.tryparse(::Type{SearchTarget}, s::AbstractString) =
    try parse(SearchTarget, s) catch e
        e isa SearchTargetParseError ? nothing : rethrow()
    end
Base.tryparse(::Type{UPnPURN}, s::AbstractString) =
    try parse(UPnPURN, s) catch e
        e isa UrnParseError ? nothing : rethrow()
    end

""" Parsed SSDP reply. Header keys are stored upper-cased. """
struct SsdpReply
    status_line::String
    headers::Dict{String,String}
    raw::String
end

Base.getproperty(r::SsdpReply, s::Symbol) =
    s in (:status_line, :headers, :raw) ? getfield(r, s) :
    s === :location ? get(getfield(r, :headers), "LOCATION", nothing) :
    s === :usn      ? get(getfield(r, :headers), "USN", nothing) :
    s === :server   ? get(getfield(r, :headers), "SERVER", nothing) :
    s === :st       ? _parse_st(get(getfield(r, :headers), "ST", nothing)) :
    error("SsdpReply has no property $s")

_parse_st(::Nothing) = nothing
_parse_st(s) = tryparse(SearchTarget, s)

""" Decode a raw SSDP reply string into an `SsdpReply`. """
function parse_ssdp_reply(raw::AbstractString)
    lines = split(raw, r"\r?\n")
    status = isempty(lines) ? "" : String(strip(first(lines)))
    headers = Dict{String,String}()
    for line in lines[2:end]
        i = findfirst(':', line)
        i === nothing && continue
        headers[uppercase(String(strip(line[1:i-1])))] = String(strip(line[i+1:end]))
    end
    SsdpReply(status, headers, String(raw))
end

""" Build an M-SEARCH request for the given target. """
function _msearch_request(target::SearchTarget; mx::Integer = 10)
    "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n" *
    "ST: $(string(target))\r\nMX: $mx\r\n\r\n"
end

"""
    probe_network(filter_text = ""; target = AllDevices(), timeout_secs = 10 * 60)

Send repeated M-SEARCH queries and optionally filter replies.

`filter_text` is an optional case-insensitive regex.  
`target` is the `SearchTarget` to request.  
Returns captured groups (if any), the whole matching reply, or `nothing` on timeout.
Network and request errors are thrown to the caller.
"""
function probe_network(filter_text = ""; target::SearchTarget = AllDevices(), timeout_secs = 10 * 60)
    req = _msearch_request(target; mx = clamp(floor(Int, timeout_secs) - 1, 1, 5))
    deadline = time() + timeout_secs
    while time() < deadline
        sock = UDPSocket()
        expired = Ref(false)
        tmr = Timer(max(0.0, deadline - time())) do _
            expired[] = true
            close(sock)
        end
        try
            bind(sock, ip"0.0.0.0", 0) || error("unable to bind UDP socket")
            send(sock, SSDP_MULTICAST, SSDP_PORT, req)
            reply = String(recv(sock))
            if filter_text == ""
                println("Received reply:\r\n$reply")
            else
                rx = Regex(filter_text, "is")
                if (m = match(rx, reply)) !== nothing
                    length(m.captures) > 0 && return m.captures
                    return reply
                end
            end
        catch err
            err isa InterruptException && rethrow()
            expired[] || rethrow()
        finally
            close(tmr)
            close(sock)
        end
        sleep(3)
    end
    return nothing
end

"""
    collect_replies(target = AllDevices(); timeout_secs = 5, mx = 3)::Vector{SsdpReply}

Perform a single M-SEARCH and gather every distinct reply received within the timeout.
"""
function collect_replies(target::SearchTarget = AllDevices(); timeout_secs = 5, mx = 3)
    sock = UDPSocket()
    expired = Ref(false)
    tmr = Timer(timeout_secs) do _
        expired[] = true
        close(sock)
    end
    results = SsdpReply[]
    seen = Set{String}()
    try
        bind(sock, ip"0.0.0.0", 0) || error("unable to bind UDP socket")
        send(sock, SSDP_MULTICAST, SSDP_PORT, _msearch_request(target; mx = mx))
        while true
            raw = String(recv(sock))
            r = parse_ssdp_reply(raw)
            key = something(r.usn, raw)
            key in seen && continue
            push!(seen, key)
            push!(results, r)
        end
    catch err
        err isa InterruptException && rethrow()
        expired[] || rethrow()
    finally
        close(tmr)
        close(sock)
    end
    return results
end


""" Description of a single service advertised by a device. All URLs are absolute. """
struct ServiceEndpoint
    type_uri::String
    id::String
    scpd_url::String
    control_url::String
    event_url::String
end

""" Tree node representing a device (and any nested devices). """
struct DeviceNode
    type_uri::String
    friendly_name::String
    manufacturer::String
    model_name::String
    udn::String
    location::String
    services::Vector{ServiceEndpoint}
    children::Vector{DeviceNode}
end

Base.show(io::IO, s::ServiceEndpoint) = print(io, "ServiceEndpoint(", s.type_uri, ")")
Base.show(io::IO, d::DeviceNode) =
    print(io, "DeviceNode(\"", d.friendly_name, "\", ", d.type_uri, ", ",
          length(d.services), " services, ", length(d.children), " children)")

# Namespace-agnostic XML helpers
_xml_children(node, tag) = [e for e in eachelement(node) if nodename(e) == tag]
function _xml_text(node, tag)
    kids = _xml_children(node, tag)
    isempty(kids) ? "" : String(strip(nodecontent(first(kids))))
end
_abs_url(base, rel) = isempty(rel) ? "" : string(HTTP.URIs.resolvereference(base, rel))

function _parse_device_node(node, base, location)
    services = ServiceEndpoint[]
    for list in _xml_children(node, "serviceList"), svc in _xml_children(list, "service")
        push!(services, ServiceEndpoint(
            _xml_text(svc, "serviceType"),
            _xml_text(svc, "serviceId"),
            _abs_url(base, _xml_text(svc, "SCPDURL")),
            _abs_url(base, _xml_text(svc, "controlURL")),
            _abs_url(base, _xml_text(svc, "eventSubURL"))))
    end
    children = DeviceNode[]
    for list in _xml_children(node, "deviceList"), dev in _xml_children(list, "device")
        push!(children, _parse_device_node(dev, base, location))
    end
    DeviceNode(_xml_text(node, "deviceType"), _xml_text(node, "friendlyName"),
               _xml_text(node, "manufacturer"), _xml_text(node, "modelName"),
               _xml_text(node, "UDN"), location, services, children)
end

"""
    load_device(url; timeout = 5)::DeviceNode
    load_device(reply::SsdpReply; timeout = 5)::DeviceNode

Download a device description document and turn it into a `DeviceNode` tree.
"""
function load_device(url::AbstractString; timeout = 5)
    resp = HTTP.get(url; readtimeout = timeout, connect_timeout = timeout)
    parse_device_xml(String(resp.body), url)
end

"""
    parse_device_xml(xml, location)::DeviceNode

Parse a device-description document. `location` is the URL the document was fetched from
(used to resolve relative service URLs when no `URLBase` is present).
"""
function parse_device_xml(xml::AbstractString, location::AbstractString)
    root_node = root(parsexml(xml))
    devices = _xml_children(root_node, "device")
    isempty(devices) && error("no <device> element found in description at $location")
    base_url = _xml_text(root_node, "URLBase")
    base = isempty(base_url) ? String(location) : base_url
    _parse_device_node(first(devices), base, String(location))
end

function load_device(r::SsdpReply; kw...)
    r.location === nothing && error("reply lacks a LOCATION header")
    load_device(r.location; kw...)
end

"""
    find_service(device, target)::Union{ServiceEndpoint,Nothing}

Search a device tree for a service that matches `target` (an `UPnPURN` or a string).
The service version must be at least as high as the requested version.
"""
function find_service(device::DeviceNode, target::UPnPURN)
    for s in device.services
        u = tryparse(UPnPURN, s.type_uri)
        u === nothing && continue
        if u.kind === target.kind && u.domain == target.domain &&
           u.name == target.name && u.ver >= target.ver
            return s
        end
    end
    for child in device.children
        found = find_service(child, target)
        found === nothing || return found
    end
    return nothing
end
find_service(device::DeviceNode, target::AbstractString) =
    find_service(device, parse(UPnPURN, target))


""" Fault reported by a device inside a SOAP response. """
struct SoapFault <: Exception
    code::Int
    message::String
end
Base.showerror(io::IO, e::SoapFault) =
    print(io, "SoapFault ", e.code, ": ", e.message)

_xml_escape(s) = replace(string(s),
    '&' => "&amp;", '<' => "&lt;", '>' => "&gt;",
    '"' => "&quot;", '\'' => "&apos;")

function _validate_xml_name(name)
    occursin(r"^[A-Za-z_][A-Za-z0-9_.-]*$", name) ||
        throw(ArgumentError("invalid XML element name: $(repr(name))"))
    name
end

function _soap_argument(name, value)
    name = _validate_xml_name(string(name))
    "<$name>$(_xml_escape(value))</$name>"
end

function _soap_envelope(type_uri, action, args)
    _validate_xml_name(action)
    inner = join((_soap_argument(k, v) for (k, v) in pairs(args)))
    """<?xml version="1.0"?>""" *
    """<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" """ *
    """s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>""" *
    """<u:$action xmlns:u="$(_xml_escape(type_uri))">$inner</u:$action></s:Body></s:Envelope>"""
end

"""
    invoke_action(service, action; timeout = 5, args...) -> Dict{String,String}

Invoke a SOAP action on the given service endpoint. Keyword arguments become
the ordered input parameters. Returns the output parameters as a dictionary.
Throws `SoapFault` when the device reports an error.
"""
function invoke_action(service::ServiceEndpoint, action::AbstractString; timeout = 5, args...)
    occursin(r"[\r\n\"]", service.type_uri) &&
        throw(ArgumentError("service type URI contains an invalid SOAP header character"))
    headers = ["Content-Type" => "text/xml; charset=\"utf-8\"",
               "SOAPACTION" => "\"$(service.type_uri)#$action\""]
    resp = HTTP.post(service.control_url, headers,
                     _soap_envelope(service.type_uri, action, args);
                     status_exception = false,
                     request_timeout = timeout, connect_timeout = timeout)
    _parse_soap_body(String(resp.body), resp.status, service.control_url)
end

function _parse_soap_body(body::AbstractString, status::Integer, url::AbstractString = "")
    doc = try
        parsexml(body)
    catch
        error("device returned unparseable body (HTTP $status)")
    end
    bodies = findall("//*[local-name()='Body']", doc)
    isempty(bodies) && error("SOAP response has no Body (HTTP $status)")
    payload = first(eachelement(first(bodies)))

    if nodename(payload) == "Fault"
        code, desc = 0, "unknown error"
        for e in findall(".//*[local-name()='UPnPError']", payload)
            code = something(tryparse(Int, _xml_text(e, "errorCode")), 0)
            desc = _xml_text(e, "errorDescription")
        end
        throw(SoapFault(code, desc))
    end
    status >= 400 && error("HTTP $status from $url")
    Dict{String,String}(nodename(e) => String(strip(nodecontent(e)))
                        for e in eachelement(payload))
end

const GATEWAY_URN = make_device_urn("schemas-upnp-org", "InternetGatewayDevice", 1)
const WAN_URNS = (make_service_urn("schemas-upnp-org", "WANIPConnection", 1),
                  make_service_urn("schemas-upnp-org", "WANPPPConnection", 1))

"""
    find_gateway(; timeout_secs = 5)

Discover the first Internet Gateway Device (router) and load its description.
If replies were received but all device descriptions failed to load, throws a
`CompositeException` containing those failures.
"""
function find_gateway(; timeout_secs = 5)
    errors = Any[]
    for r in collect_replies(GATEWAY_URN; timeout_secs = timeout_secs)
        try
            return load_device(r)
        catch err
            err isa InterruptException && rethrow()
            push!(errors, err)
        end
    end
    isempty(errors) || throw(CompositeException(errors))
    error("No Internet Gateway Device found on the network")
end

function _wan_service(gateway::DeviceNode)
    for urn in WAN_URNS
        s = find_service(gateway, urn)
        s === nothing || return s
    end
    error("Gateway \"$(gateway.friendly_name)\" has no WANIPConnection or WANPPPConnection service")
end

""" Ask the router for its external (WAN) IP address. """
external_ip_address(gateway::DeviceNode = find_gateway()) =
    invoke_action(_wan_service(gateway), "GetExternalIPAddress")["NewExternalIPAddress"]

"""
    add_port_forward(gateway; external_port, internal_port = external_port,
                     internal_client = string(getipaddr()), protocol = "TCP",
                     description = "UPnPClient.jl", lease_secs = 0)

Forward `external_port` on the router to `internal_client:internal_port`.
`lease_secs` is in seconds; 0 means permanent (some routers reject this).
"""
function add_port_forward(gateway::DeviceNode; external_port::Integer,
                          internal_port::Integer = external_port,
                          internal_client::AbstractString = string(getipaddr()),
                          protocol::AbstractString = "TCP",
                          description::AbstractString = "UPnPClient.jl",
                          lease_secs::Integer = 0)
    invoke_action(_wan_service(gateway), "AddPortMapping";
                  NewRemoteHost = "",
                  NewExternalPort = external_port,
                  NewProtocol = uppercase(protocol),
                  NewInternalPort = internal_port,
                  NewInternalClient = internal_client,
                  NewEnabled = 1,
                  NewPortMappingDescription = description,
                  NewLeaseDuration = lease_secs)
    nothing
end

""" Remove a previously created port mapping on the router. """
function remove_port_forward(gateway::DeviceNode; external_port::Integer,
                             protocol::AbstractString = "TCP")
    invoke_action(_wan_service(gateway), "DeletePortMapping";
                  NewRemoteHost = "",
                  NewExternalPort = external_port,
                  NewProtocol = uppercase(protocol))
    nothing
end


end # module UPnPClient
