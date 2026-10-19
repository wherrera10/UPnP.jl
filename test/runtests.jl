using Test, UPnPClient

# NOTE: To use in the CI sandbox actual network usage in testing
# is disabled by default. To include a brief live network test, set the
# environment variable ENV["UPNP_NETWORK_TESTS"] = "1".
# This will run collect_replies against your actual LAN.

@testset "UPnPClient                                        " begin

    @testset "Parse a SearchTarget " begin
        @test parse(SearchTarget, "ssdp:all") == AllDevices()
        @test parse(SearchTarget, "upnp:rootdevice") == RootDeviceOnly()
        @test parse(SearchTarget, "uuid:some-uuid") == DeviceUUID("some-uuid")
        @test_throws SearchTargetParseError parse(SearchTarget, "uuid")
        @test_throws SearchTargetParseError parse(SearchTarget, "uuidx")
        @test_throws SearchTargetParseError parse(SearchTarget, "uuid:")
        @test parse(SearchTarget, "urn:schemas-upnp-org:device:ZonePlayer:1") ==
            UPnPURN(:device, "schemas-upnp-org", "ZonePlayer", 1)
        @test parse(SearchTarget, "urn:schemas-sonos-com:service:Queue:2") ==
            UPnPURN(:service, "schemas-sonos-com", "Queue", 2)
        @test parse(SearchTarget, "roku:ecp") == CustomTarget("roku", "ecp")
    end

    @testset "Check SearchTarget parsing errors             " begin
        @test_throws SearchTargetParseError parse(SearchTarget, "nocolon")
        @test_throws SearchTargetParseError parse(SearchTarget, "a:b:c")
        @test_throws SearchTargetParseError parse(SearchTarget, "urn:bad")
        err = try
            parse(SearchTarget, "urn:bad")
            nothing
        catch e
            e
        end
        @test err isa SearchTargetParseError
        @test err.nested isa UrnParseError
        @test tryparse(SearchTarget, "a:b:c") === nothing
        @test tryparse(SearchTarget, "roku:ecp") == CustomTarget("roku", "ecp")
    end

    @testset "Parse a URN                                   " begin
        u = parse(UPnPURN, "urn:schemas-upnp-org:service:RenderingControl:1")
        @test urn_kind(u) === :service
        @test urn_domain(u) == "schemas-upnp-org"
        @test urn_type(u) == "RenderingControl"
        @test urn_version(u) == 1

        # kind is matched case-insensitively and normalized to lower case
        u2 = parse(UPnPURN, "urn:x:SERVICE:Y:3")
        @test urn_kind(u2) === :service
        @test string(u2) == "urn:x:service:Y:3"
        @test urn_kind(parse(UPnPURN, "urn:x:Device:Y:1")) === :device

        @test_throws UrnParseError parse(UPnPURN, "")
        @test_throws UrnParseError parse(UPnPURN, "uri:a:service:b:1") # wrong scheme
        @test_throws UrnParseError parse(UPnPURN, "urn:a:service:b") # too few parts
        @test_throws UrnParseError parse(UPnPURN, "urn:a:service:b:1:more") # too many parts
        @test_throws UrnParseError parse(UPnPURN, "urn:a:fridge:b:1") # bad kind
        @test_throws UrnParseError parse(UPnPURN, "urn:a:service:b:x") # bad version
        @test_throws UrnParseError parse(UPnPURN, "urn:a:service:b:-1") # negative version
        @test tryparse(UPnPURN, "urn:a:service:b:x") === nothing
    end

    @testset "Display round-trips via parsing               " begin
        for s in [
                "ssdp:all",
                "upnp:rootdevice",
                "uuid:abc-123",
                "urn:schemas-upnp-org:device:ZonePlayer:1",
                "urn:schemas-sonos-com:service:Queue:2",
                "roku:ecp",
            ]
            @test string(parse(SearchTarget, s)) == s
        end
    end

    @testset "URN functions: constructors, ordering, hashing" begin
        d = make_device_urn("schemas-upnp-org", "X", 1)
        s = make_service_urn("schemas-upnp-org", "X", 1)
        @test urn_kind(d) === :device && urn_kind(s) === :service
        @test d < s # Device < Service
        @test make_service_urn("a", "B", 1) < make_service_urn("a", "B", 2)
        @test make_service_urn("a", "B", 2) < make_service_urn("a", "C", 1)
        @test sort([s, d]) == [d, s]
        @test d == make_device_urn("schemas-upnp-org", "X", 1)
        @test hash(d) == hash(make_device_urn("schemas-upnp-org", "X", 1))
        @test length(Set([d, d, s])) == 2
        @test d isa SearchTarget
        @test_throws ArgumentError UPnPURN(:gadget, "a", "b", 1)
    end

    @testset "Parse SSDP replies                            " begin
        raw = "HTTP/1.1 200 OK\r\n" *
            "CACHE-CONTROL: max-age=1800\r\n" *
            "Location: http://192.168.1.1:1900/rootDesc.xml\r\n" *
            "ST: upnp:rootdevice\r\n" *
            "USN: uuid:abc::upnp:rootdevice\r\n" *
            "SERVER: Linux UPnPNet/1.1 MiniUPnPd/2.1\r\n\r\n"
        r = parse_ssdp_reply(raw)
        @test r.status_line == "HTTP/1.1 200 OK"
        @test r.location ==
            "http://192.168.1.1:1900/rootDesc.xml" # header names are case-insensitive
        @test r.usn == "uuid:abc::upnp:rootdevice"
        @test r.server == "Linux UPnPNet/1.1 MiniUPnPd/2.1"
        @test r.st == RootDeviceOnly()
        @test r.headers["CACHE-CONTROL"] == "max-age=1800"
        @test r.raw == raw

        bare = parse_ssdp_reply("HTTP/1.1 200 OK\r\n\r\n")
        @test bare.location === nothing
        @test bare.st === nothing
    end

    # SOAP XML reply example used for testing XML parsing
    router_xml = """<?xml version="1.0"?>
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

    @testset "parse_device_xml                              " begin
        loc = "http://192.168.1.1:5000/rootDesc.xml"
        dev = parse_device_xml(router_xml, loc)

        @test dev.friendly_name == "Test Router"
        @test dev.manufacturer == "Acme"
        @test dev.model_name == "R1"
        @test dev.udn == "uuid:1234"
        @test dev.location == loc
        @test dev.type_uri == "urn:schemas-upnp-org:device:InternetGatewayDevice:1"

        # service URLs are resolved against the description URL
        @test length(dev.services) == 1
        svc = dev.services[1]
        @test svc.type_uri == "urn:schemas-upnp-org:service:Layer3Forwarding:1"
        @test svc.id == "urn:upnp-org:serviceId:L3Forwarding1"
        @test svc.scpd_url == "http://192.168.1.1:5000/L3F.xml"
        @test svc.control_url == "http://192.168.1.1:5000/ctl/L3F"
        @test svc.event_url == "http://192.168.1.1:5000/evt/L3F"

        # embedded devices
        @test length(dev.children) == 1
        @test dev.children[1].friendly_name == "WANDevice"
        @test dev.children[1].children[1].friendly_name == "WANConnectionDevice"

        @test_throws ErrorException parse_device_xml("<root/>", loc)
    end

    @testset "URLBase overrides the description location    " begin
        # URLBase is a child of <root>, placed before <device>
        xml = replace(
            router_xml,
            "<specVersion>" => "<URLBase>http://10.0.0.1:49000/</URLBase><specVersion>";
            count = 1,
        )
        dev = parse_device_xml(xml, "http://192.168.1.1:5000/rootDesc.xml")
        @test dev.services[1].control_url == "http://10.0.0.1:49000/ctl/L3F"
    end

    @testset "find_service                                  " begin
        dev = parse_device_xml(router_xml, "http://192.168.1.1:5000/rootDesc.xml")

        # for embedded device, allow a v2 service to satisfy a v1 request
        s = find_service(dev, make_service_urn("schemas-upnp-org", "WANIPConnection", 1))
        @test s !== nothing
        @test s.control_url == "http://192.168.1.1:5000/ctl/IPConn"

        # string targets are the simplest
        @test find_service(dev, "urn:schemas-upnp-org:service:WANIPConnection:2") !==
            nothing

        # too-new version, wrong name, wrong kind should not be found
        @test find_service(
            dev,
            make_service_urn("schemas-upnp-org", "WANIPConnection", 3),
        ) ===
            nothing
        @test find_service(dev, make_service_urn("schemas-upnp-org", "Nope", 1)) === nothing
        @test find_service(
            dev,
            make_device_urn("schemas-upnp-org", "WANIPConnection", 1),
        ) ===
            nothing

        # top-level service
        @test find_service(dev, "urn:schemas-upnp-org:service:Layer3Forwarding:1") !==
            nothing
    end

    @testset "SOAP envelope                                 " begin
        st = "urn:schemas-upnp-org:service:RenderingControl:1"
        env = UPnPClient._soap_envelope(
            st,
            "SetVolume",
            (InstanceID = 0, Channel = "Master", Desired = "a<b&c"),
        )
        @test occursin("<u:SetVolume xmlns:u=\"$st\">", env)
        @test occursin("<InstanceID>0</InstanceID>", env)
        @test occursin("<Desired>a&lt;b&amp;c</Desired>", env)
        @test occursin("xmlns:u=\"$st\"", env)
        # argument order is preserved
        @test findfirst("<InstanceID>", env).start <
            findfirst("<Channel>", env).start <
            findfirst("<Desired>", env).start
        @test occursin("</s:Body></s:Envelope>", env)

        # the whole thing must be well-formed XML
        @test UPnPClient.EzXML.parsexml(env) isa UPnPClient.EzXML.Document
        escaped_uri = UPnPClient._soap_envelope(
            "urn:example?one=1&two=2", "Action", NamedTuple())
        @test occursin("xmlns:u=\"urn:example?one=1&amp;two=2\"", escaped_uri)
        @test UPnPClient.EzXML.parsexml(escaped_uri) isa UPnPClient.EzXML.Document
        @test_throws ArgumentError UPnPClient._soap_envelope(st, "Bad><Action", NamedTuple())
        @test_throws ArgumentError UPnPClient._soap_argument("bad>", "value")
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
        out = UPnPClient._parse_soap_body(ok, 200)
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
        @test_throws SoapFault UPnPClient._parse_soap_body(fault, 500)
        err = try
            UPnPClient._parse_soap_body(fault, 500)
            nothing
        catch e
            e
        end
        @test err.code == 718
        @test err.message == "ConflictInMappingEntry"

        @test_throws ErrorException UPnPClient._parse_soap_body("not xml at all", 200)
        @test_throws ErrorException UPnPClient._parse_soap_body("<a/>", 200) # no Body
    end

    @testset "M-SEARCH request                              " begin
        req = UPnPClient._msearch_request(parse(SearchTarget, "roku:ecp"); mx = 3)
        @test startswith(req, "M-SEARCH * HTTP/1.1\r\n")
        @test occursin("ST: roku:ecp\r\n", req)
        @test occursin("MX: 3\r\n", req)
        @test occursin("MAN: \"ssdp:discover\"", req)
        @test endswith(req, "\r\n\r\n")
        @test occursin("ST: ssdp:all\r\n", UPnPClient._msearch_request(AllDevices()))
    end

    if get(ENV, "UPNP_NETWORK_TESTS", "0") == "1"
        @testset "live network                              " begin
            found = collect_replies(AllDevices(); timeout_secs = 5)
            @test found isa Vector{SsdpReply}
            println("Found $(length(found)) SSDP responders")
            for r in found
                @test r.location !== nothing || r.usn !== nothing
            end
        end
    end
end

true
