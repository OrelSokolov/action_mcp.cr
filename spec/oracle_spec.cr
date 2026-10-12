# Oracle mirror: the same 29 cases as oracle/cases.rb, captured from the
# official MCP Ruby SDK 1.7.0 (oracle/expected.yml) — same case IDs,
# byte-for-byte bodies, run through ActionMCP::ServerController exactly
# as the mounted /mcp endpoint would (controller-level, full action_pack
# dispatch). Protocol layer is pure; the transport guards (Accept /
# Content-Type / GET / DELETE) go through the controller actions.

require "spec"
require "http"
require "../src/action_mcp_cr"

# --- the oracle's tools, in Crystal (ActiveAgent::Tool) ----------------------

class EchoTool
  include ActiveAgent::Tool
  description "Echo back a message"
  input message : String, times : Int32?

  def call : ActiveAgent::ToolResult
    ActiveAgent::ToolResult.ok(message * (times || 1))
  end
end

class BoomTool
  include ActiveAgent::Tool
  description "Always fails"
  input

  def call : ActiveAgent::ToolResult
    raise "boom"
  end
end

class OracleMcp < ActionMCP::Server
  server_name "crails_oracle"
  server_version "1.2.3"
  tools EchoTool, BoomTool
end

ActionMCP.mount = OracleMcp

# --- helpers ------------------------------------------------------------------

private def run_endpoint(method : String, action : String, *,
                         accept : String? = "application/json",
                         content_type : String? = "application/json",
                         body : String? = nil) : String
  headers = HTTP::Headers.new
  headers["Accept"] = accept unless accept.nil?
  headers["Content-Type"] = content_type unless content_type.nil?
  request = HTTP::Request.new(method, "/mcp", headers, body: body && IO::Memory.new(body))
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(request, response)
  controller = ActionMCP::ServerController.new(context)
  controller.__set_params({} of String => String)
  controller.__run_action(action)
  context.response.close
  response_body = io.to_s.split("\r\n\r\n", 2).last? || ""
  ct = response.headers["Content-Type"]?
  "#{response.status_code}|#{ct.to_s}|#{response_body}"
end

private def post_mcp(body : String, *, accept : String? = "application/json",
                     content_type : String? = "application/json") : String
  run_endpoint("POST", "create", accept: accept, content_type: content_type, body: body)
end

private def expected : Hash(String, String)
  {} of String => String
end

expected_cases = File.read(__DIR__ + "/../oracle/expected.yml").each_line
  .reject(&.empty?)
  .map { |l| {l.split("\t", 2)[0], l.split("\t", 2)[1]? || ""} }
  .to_h

private def j(h : String) : String
  h
end

def it_matches_oracle(case_id : String, actual : String, cases : Hash(String, String)) : Nil
  it "oracle #{case_id}" do
    actual.should eq(cases[case_id])
  end
end

# --- the 29 oracle cases --------------------------------------------------------

INIT = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}})

oracle_cases = {
  "init_ok"                => post_mcp(INIT),
  "init_latest"            => post_mcp(INIT.gsub("2025-06-18", "2025-11-25")),
  "init_unknown_version"   => post_mcp(INIT.gsub("2025-06-18", "1999-01-01")),
  "init_missing_params"    => post_mcp(%({"jsonrpc":"2.0","id":2,"method":"initialize"})),
  "notif_initialized"      => post_mcp(%({"jsonrpc":"2.0","method":"notifications/initialized"})),
  "notif_cancelled"        => post_mcp(%({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":13}})),
  "ping"                   => post_mcp(%({"jsonrpc":"2.0","id":3,"method":"ping"})),
  "ping_string_id"         => post_mcp(%({"jsonrpc":"2.0","id":"str-id","method":"ping"})),
  "tools_list"             => post_mcp(%({"jsonrpc":"2.0","id":4,"method":"tools/list"})),
  "call_ok"                => post_mcp(%({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo_tool","arguments":{"message":"hi","times":2}}})),
  "call_raise"             => post_mcp(%({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"boom_tool","arguments":{}}})),
  "call_unknown_tool"      => post_mcp(%({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"nope","arguments":{}}})),
  "call_missing_required"  => post_mcp(%({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"echo_tool","arguments":{}}})),
  "call_no_arguments"      => post_mcp(%({"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"echo_tool"}})),
  "call_wrong_type_int"    => post_mcp(%({"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"echo_tool","arguments":{"message":"hi","times":"x"}}})),
  "call_wrong_type_string" => post_mcp(%({"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"echo_tool","arguments":{"message":7}}})),
  "resources_list"         => post_mcp(%({"jsonrpc":"2.0","id":9,"method":"resources/list"})),
  "resources_read"         => post_mcp(%({"jsonrpc":"2.0","id":11,"method":"resources/read","params":{"uri":"file:///x"}})),
  "prompts_list"           => post_mcp(%({"jsonrpc":"2.0","id":10,"method":"prompts/list"})),
  "method_not_found"       => post_mcp(%({"jsonrpc":"2.0","id":12,"method":"bogus/method"})),
  "parse_error"            => post_mcp("{bad json"),
  "parse_trailing_garbage" => post_mcp(%({"jsonrpc":"2.0","id":15,"method":"ping"}extra)),
  "batch_rejected"         => post_mcp(%([{"jsonrpc":"2.0","id":1,"method":"initialize"}])),
  "accept_missing"         => post_mcp(INIT, accept: nil),
  "accept_sse_only"        => post_mcp(INIT, accept: "text/event-stream"),
  "content_type_wrong"     => post_mcp(INIT, content_type: "text/plain"),
  "get_405"                => run_endpoint("GET", "show"),
  "delete_200"             => run_endpoint("DELETE", "destroy"),
}

describe "action_mcp oracle (MCP Ruby SDK 1.7.0 wire)" do
  oracle_cases.each do |case_id, actual|
    it_matches_oracle(case_id, actual, expected_cases)
  end
end
