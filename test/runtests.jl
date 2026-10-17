using Test

# NOTE: To use in the CI sandbox actual network usage in testing 
# is disabled by default. To include a brief live network test, set the 
# environment variable ENV[UPNP_NETWORK_TESTS] = "1". 
# This will run the discover function against your actual LAN.

using .UniversalPlugAndPlay

@testset "UniversalPlugAndPlay                          " begin

    @testset "Parse a SearchTarget " begin
        @test parse(SearchTarget, "ssdp:all") == All()
        @test parse(SearchTarget, "upnp:rootdevice") == RootDevice()
        @test parse(SearchTarget, "uuid:some-uuid") == UUID("some-uuid")
        @test parse(SearchTarget, "urn:schemas-upnp-org:device:ZonePlayer:1") ==
              URN(:device, "schemas-upnp-org", "ZonePlayer", 1)
        @test parse(SearchTarget, "urn:schemas-sonos-com:service:Queue:2") ==
              URN(:service, "schemas-sonos-com", "Queue", 2)
        @test parse(SearchTarget, "roku:ecp") == Custom("roku", "ecp")
    end

    @testset "Check SearchTarget parsing errors             " begin
        @test_throws ParseSearchTargetError parse(SearchTarget, "nocolon")
        @test_throws ParseSearchTargetError parse(SearchTarget, "a:b:c")
        @test_throws ParseSearchTargetError parse(SearchTarget, "urn:bad")
        err = try parse(SearchTarget, "urn:bad"); nothing catch e; e end
        @test err isa ParseSearchTargetError
        @test err.cause isa ParseURNError
        @test tryparse(SearchTarget, "a:b:c") === nothing
        @test tryparse(SearchTarget, "roku:ecp") == Custom("roku", "ecp")
    end

    @testset "Parse a URN                                   " begin
        u = parse(URN, "urn:schemas-upnp-org:service:RenderingControl:1")
        @test kind(u) === :service
        @test domain_name(u) == "schemas-upnp-org"
        @test typ(u) == "RenderingControl"
        @test version(u) == 1

        # kind is matched case-insensitively and normalized to lower case
        u2 = parse(URN, "urn:x:SERVICE:Y:3")
        @test kind(u2) === :service
        @test string(u2) == "urn:x:service:Y:3"
        @test kind(parse(URN, "urn:x:Device:Y:1")) === :device

        @test_throws ParseURNError parse(URN, "")
        @test_throws ParseURNError parse(URN, "uri:a:service:b:1")      # wrong scheme
        @test_throws ParseURNError parse(URN, "urn:a:service:b")        # too few parts
        @test_throws ParseURNError parse(URN, "urn:a:service:b:1:more") # too many parts
        @test_throws ParseURNError parse(URN, "urn:a:fridge:b:1")       # bad kind
        @test_throws ParseURNError parse(URN, "urn:a:service:b:x")      # bad version
        @test_throws ParseURNError parse(URN, "urn:a:service:b:-1")     # negative version
        @test tryparse(URN, "urn:a:service:b:x") === nothing
    end

    @testset "Display round-trips via parsing               " begin
        for s in ["ssdp:all", "upnp:rootdevice", "uuid:abc-123",
                  "urn:schemas-upnp-org:device:ZonePlayer:1",
                  "urn:schemas-sonos-com:service:Queue:2", "roku:ecp"]
            @test string(parse(SearchTarget, s)) == s
        end
    end

    @testset "URN functions: constructors, ordering, hashing" begin
        d = device_urn("schemas-upnp-org", "X", 1)
        s = service_urn("schemas-upnp-org", "X", 1)
        @test kind(d) === :device && kind(s) === :service
        @test d < s                                   # Device < Service, as in Rust
        @test service_urn("a", "B", 1) < service_urn("a", "B", 2)
        @test service_urn("a", "B", 2) < service_urn("a", "C", 1)
        @test sort([s, d]) == [d, s]
        @test d == device_urn("schemas-upnp-org", "X", 1)
        @test hash(d) == hash(device_urn("schemas-upnp-org", "X", 1))
        @test length(Set([d, d, s])) == 2
        @test d isa SearchTarget                      # From<URN> for SearchTarget
        @test_throws ArgumentError URN(:gadget, "a", "b", 1)
    end

    @testset "Parse SSDP replies                            " begin
        raw = "HTTP/1.1 200 OK\r\n" *
              "CACHE-CONTROL: max-age=1800\r\n" *
              "Location: http://192.168.1.1:1900/rootDesc.xml\r\n" *
              "ST: upnp:rootdevice\r\n" *
              "USN: uuid:abc::upnp:rootdevice\r\n" *
              "SERVER: Linux UPnP/1.1 MiniUPnPd/2.1\r\n\r\n"
        r = parse_response(raw)
        @test r.status == "HTTP/1.1 200 OK"
        @test r.location == "http://192.168.1.1:1900/rootDesc.xml"   # header names are case-insensitive
        @test r.usn == "uuid:abc::upnp:rootdevice"
        @test r.server == "Linux UPnP/1.1 MiniUPnPd/2.1"
        @test r.st == RootDevice()
        @test r.headers["CACHE-CONTROL"] == "max-age=1800"
        @test r.raw == raw

        bare = parse_response("HTTP/1.1 200 OK\r\n\r\n")
        @test bare.location === nothing
        @test bare.st === nothing
    end

    # SOAP XML reply example used for testing XML parsing
    const router_xml = """<?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <device>
        <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
        <friendlyName>Test Router</friendlyName>
        <manufacturer>Acme</manufacturer>
        <modelName>R1</modelName>
        <UDN>uuid:1234</UDN>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
            <serviceId>urn:upnp-org:serviceId:L3Forwarding1</serviceId>
            <SCPDURL>/L3F.xml</SCPDURL>
            <controlURL>/ctl/L3F</controlURL>
            <eventSubURL>/evt/L3F</eventSubURL>
          </service>
        </serviceList>
        <deviceList>
          <device>
            <deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>
            <friendlyName>WANDevice</friendlyName>
            <manufacturer>Acme</manufacturer>
            <modelName>W1</modelName>
            <UDN>uuid:1234-wan</UDN>
            <deviceList>
              <device>
                <deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType>
                <friendlyName>WANConnectionDevice</friendlyName>
                <manufacturer>Acme</manufacturer>
                <modelName>C1</modelName>
                <UDN>uuid:1234-conn</UDN>
                <serviceList>
                  <service>
                    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType>
                    <serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>
                    <SCPDURL>/WANIPCn.xml</SCPDURL>
                    <controlURL>/ctl/IPConn</controlURL>
                    <eventSubURL>/evt/IPConn</eventSubURL>
                  </service>
                </serviceList>
              </device>
            </deviceList>
          </device>
        </deviceList>
      </device>
    </root>"""

    @testset "parse_device                                  " begin
        loc = "http://192.168.1.1:5000/rootDesc.xml"
        dev = parse_device(router_xml, loc)

        @test dev.friendly_name == "Test Router"
        @test dev.manufacturer == "Acme"
        @test dev.model_name == "R1"
        @test dev.udn == "uuid:1234"
        @test dev.location == loc
        @test dev.device_type == "urn:schemas-upnp-org:device:InternetGatewayDevice:1"

        # service URLs are resolved against the description URL
        @test length(dev.services) == 1
        svc = dev.services[1]
        @test svc.service_type == "urn:schemas-upnp-org:service:Layer3Forwarding:1"
        @test svc.service_id == "urn:upnp-org:serviceId:L3Forwarding1"
        @test svc.scpd_url == "http://192.168.1.1:5000/L3F.xml"
        @test svc.control_url == "http://192.168.1.1:5000/ctl/L3F"
        @test svc.event_sub_url == "http://192.168.1.1:5000/evt/L3F"

        # embedded devices
        @test length(dev.devices) == 1
        @test dev.devices[1].friendly_name == "WANDevice"
        @test dev.devices[1].devices[1].friendly_name == "WANConnectionDevice"

        @test_throws ErrorException parse_device("<root/>", loc)
    end

    @testset "URLBase overrides the description location    " begin
        # URLBase is a child of <root>, placed before <device>
        xml = replace(router_xml,
                      "<specVersion>" => "<URLBase>http://10.0.0.1:49000/</URLBase><specVersion>"; count = 1)
        dev = parse_device(xml, "http://192.168.1.1:5000/rootDesc.xml")
        @test dev.services[1].control_url == "http://10.0.0.1:49000/ctl/L3F"
    end

    @testset "find_service                                  " begin
        dev = parse_device(router_xml, "http://192.168.1.1:5000/rootDesc.xml")

        # for embedded device, allow a v2 service to satisfy a v1 request
        s = find_service(dev, service_urn("schemas-upnp-org", "WANIPConnection", 1))
        @test s !== nothing
        @test s.control_url == "http://192.168.1.1:5000/ctl/IPConn"

        # string targets are perhaps the simplest, just use something expected
        @test find_service(dev, "urn:schemas-upnp-org:service:WANIPConnection:2") !== nothing

        # too-new version, wrong name, wrong kind should not be found
        @test find_service(dev, service_urn("schemas-upnp-org", "WANIPConnection", 3)) === nothing
        @test find_service(dev, service_urn("schemas-upnp-org", "Nope", 1)) === nothing
        @test find_service(dev, device_urn("schemas-upnp-org", "WANIPConnection", 1)) === nothing

        # top-level service
        @test find_service(dev, "urn:schemas-upnp-org:service:Layer3Forwarding:1") !== nothing
    end

    @testset "SOAP envelope                                 " begin
        st = "urn:schemas-upnp-org:service:RenderingControl:1"
        env = UniversalPlugAndPlay._envelope(st, "SetVolume",
                                    (InstanceID = 0, Channel = "Master", Desired = "a<b&c"))
        @test occursin("<u:SetVolume xmlns:u=\"$st\">", env)
        @test occursin("<InstanceID>0</InstanceID>", env)
        @test occursin("<Desired>a&lt;b&amp;c</Desired>", env)
        # argument order is preserved
        @test findfirst("<InstanceID>", env).start < findfirst("<Channel>", env).start <
              findfirst("<Desired>", env).start
        @test occursin("</s:Body></s:Envelope>", env)

        # the whole thing must be well-formed XML
        @test UniversalPlugAndPlay.EzXML.parsexml(env) isa UniversalPlugAndPlay.EzXML.Document
    end

    @testset "SOAP responses                                " begin
        ok = """<?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
                    s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetExternalIPAddressResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
              <NewExternalIPAddress>203.0.113.7</NewExternalIPAddress>
            </u:GetExternalIPAddressResponse>
          </s:Body>
        </s:Envelope>"""
        out = UniversalPlugAndPlay._parse_soap_response(ok, 200)
        @test out == Dict("NewExternalIPAddress" => "203.0.113.7")

        fault = """<?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <s:Fault>
              <faultcode>s:Client</faultcode>
              <faultstring>UPnPError</faultstring>
              <detail>
                <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
                  <errorCode>718</errorCode>
                  <errorDescription>ConflictInMappingEntry</errorDescription>
                </UPnPError>
              </detail>
            </s:Fault>
          </s:Body>
        </s:Envelope>"""
        @test_throws UPnPError UniversalPlugAndPlay._parse_soap_response(fault, 500)
        err = try UniversalPlugAndPlay._parse_soap_response(fault, 500); nothing catch e; e end
        @test err.code == 718
        @test err.description == "ConflictInMappingEntry"

        @test_throws ErrorException UniversalPlugAndPlay._parse_soap_response("not xml at all", 200)
        @test_throws ErrorException UniversalPlugAndPlay._parse_soap_response("<a/>", 200)  # no Body
    end

    @testset "M-SEARCH request                              " begin
        req = UniversalPlugAndPlay.msearch(parse(SearchTarget, "roku:ecp"); mx = 3)
        @test startswith(req, "M-SEARCH * HTTP/1.1\r\n")
        @test occursin("ST: roku:ecp\r\n", req)
        @test occursin("MX: 3\r\n", req)
        @test occursin("MAN: \"ssdp:discover\"", req)
        @test endswith(req, "\r\n\r\n")
        @test occursin("ST: ssdp:all\r\n", UniversalPlugAndPlay.msearch(All()))
    end

    if get(ENV, "UPNP_NETWORK_TESTS", "0") == "1"
        @testset "live network                              " begin
            found = discover(All(); timeoutsecs = 5)
            @test found isa Vector{SSDPResponse}
            println("Found $(length(found)) SSDP responders")
            for r in found
                @test r.location !== nothing || r.usn !== nothing
            end
        end
    end
end
