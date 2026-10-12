# Oracle cases for action_mcp.cr — captured from the OFFICIAL MCP Ruby
# SDK (gem "mcp" 1.7.0, modelcontextprotocol/ruby-sdk), vendored in
# oracle/vendor. The SDK's StreamableHTTPTransport runs in stateless +
# JSON-response mode — the same mode action_mcp mounts at /mcp.
#
# Run (from the shard root):
#   ruby oracle/cases.rb > oracle/expected.yml
#
# Each line: "<case_id>\t<status>|<content-type>|<body>". Mirrored 1:1
# in spec/oracle_spec.cr (same case IDs, byte-for-byte bodies).
#
# Covers: initialize handshake (version negotiation incl. unknown →
# latest stable handshake), notifications → 202, ping, tools/list wire
# shape ($schema/properties/required/type ordering), tools/call
# ok/raise/unknown/missing-arg/wrong-type, resources/prompts stubs,
# method-not-found, JSON-RPC parse errors, batch rejection, Accept /
# Content-Type guards (406/415), GET → 405, DELETE → 200.

def line(id, value)
  puts "#{id}\t#{value}"
end

$LOAD_PATH.unshift(File.expand_path("vendor/gems/mcp-1.7.0/lib", __dir__))
%w[bigdecimal-4.1.3 hana-1.3.7 json_schemer-2.5.0 regexp_parser-2.13.1
   simpleidn-0.3.0 mcp-1.7.0].each do |g|
  path = File.expand_path("vendor/gems/#{g}/lib", __dir__)
  $LOAD_PATH.unshift(path) if File.directory?(path)
end
require "mcp"
require "rack"
require "rack/mock"

# Tools mirror the spec's oracle tools (spec/oracle_spec.cr defines the
# same two in Crystal via ActiveAgent::Tool).
class EchoTool < MCP::Tool
  description "Echo back a message"
  input_schema(
    properties: {message: {type: "string"}, times: {type: "integer"}},
    required: ["message"]
  )

  class << self
    def call(message:, times: nil, server_context:)
      MCP::Tool::Response.new([{type: "text", text: message * (times || 1)}])
    end
  end
end

class BoomTool < MCP::Tool
  description "Always fails"
  input_schema(properties: {}, required: [])
  class << self
    def call(server_context:)
      raise "boom"
    end
  end
end

server = MCP::Server.new(name: "crails_oracle", version: "1.2.3", tools: [EchoTool, BoomTool])
app = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true, enable_json_response: true)
mr = Rack::MockRequest.new(app)

def post(mr, body, accept: "application/json", ct: "application/json")
  resp = mr.post("/mcp", "CONTENT_TYPE" => ct, "HTTP_ACCEPT" => accept, :input => body)
  [resp.status, resp.headers["content-type"].to_s, resp.body].join("|")
end

J = ->(h) { JSON.generate(h) }
init = J.({jsonrpc: "2.0", id: 1, method: "initialize",
           params: {protocolVersion: "2025-06-18", capabilities: {},
                    clientInfo: {name: "probe", version: "0"}}})

line("init_ok", post(mr, init))
line("init_latest", post(mr, init.gsub("2025-06-18", "2025-11-25")))
line("init_unknown_version", post(mr, init.gsub("2025-06-18", "1999-01-01")))
line("init_missing_params", post(mr, J.({jsonrpc: "2.0", id: 2, method: "initialize"})))
line("notif_initialized", post(mr, J.({jsonrpc: "2.0", method: "notifications/initialized"})))
line("notif_cancelled", post(mr, J.({jsonrpc: "2.0", method: "notifications/cancelled", params: {requestId: 13}})))
line("ping", post(mr, J.({jsonrpc: "2.0", id: 3, method: "ping"})))
line("ping_string_id", post(mr, J.({jsonrpc: "2.0", id: "str-id", method: "ping"})))
line("tools_list", post(mr, J.({jsonrpc: "2.0", id: 4, method: "tools/list"})))
line("call_ok", post(mr, J.({jsonrpc: "2.0", id: 5, method: "tools/call",
                             params: {name: "echo_tool", arguments: {message: "hi", times: 2}}})))
line("call_raise", post(mr, J.({jsonrpc: "2.0", id: 6, method: "tools/call",
                                params: {name: "boom_tool", arguments: {}}})))
line("call_unknown_tool", post(mr, J.({jsonrpc: "2.0", id: 7, method: "tools/call",
                                       params: {name: "nope", arguments: {}}})))
line("call_missing_required", post(mr, J.({jsonrpc: "2.0", id: 8, method: "tools/call",
                                           params: {name: "echo_tool", arguments: {}}})))
line("call_no_arguments", post(mr, J.({jsonrpc: "2.0", id: 14, method: "tools/call",
                                       params: {name: "echo_tool"}})))
line("call_wrong_type_int", post(mr, J.({jsonrpc: "2.0", id: 13, method: "tools/call",
                                         params: {name: "echo_tool", arguments: {message: "hi", times: "x"}}}))
)
line("call_wrong_type_string", post(mr, J.({jsonrpc: "2.0", id: 16, method: "tools/call",
                                            params: {name: "echo_tool", arguments: {message: 7}}})))
line("resources_list", post(mr, J.({jsonrpc: "2.0", id: 9, method: "resources/list"})))
line("resources_read", post(mr, J.({jsonrpc: "2.0", id: 11, method: "resources/read",
                                    params: {uri: "file:///x"}})))
line("prompts_list", post(mr, J.({jsonrpc: "2.0", id: 10, method: "prompts/list"})))
line("method_not_found", post(mr, J.({jsonrpc: "2.0", id: 12, method: "bogus/method"})))
line("parse_error", post(mr, "{bad json"))
line("parse_trailing_garbage", post(mr, '{"jsonrpc":"2.0","id":15,"method":"ping"}extra'))
line("batch_rejected", post(mr, [init].to_json))
line("accept_missing", post(mr, init, accept: nil))
line("accept_sse_only", post(mr, init, accept: "text/event-stream"))
line("content_type_wrong", post(mr, init, ct: "text/plain"))

resp = mr.get("/mcp", "HTTP_ACCEPT" => "application/json")
line("get_405", [resp.status, resp.headers["content-type"].to_s, resp.body].join("|"))
resp = mr.delete("/mcp")
line("delete_200", [resp.status, resp.headers["content-type"].to_s, resp.body].join("|"))
