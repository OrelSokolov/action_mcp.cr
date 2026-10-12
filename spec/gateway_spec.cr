# Gateway (monetization layer) + Server DSL specs: authentication
# (401), tool scopes (403), quotas (429), usage accounting, audit
# events, `agent(...)` as an MCP tool, route drawing.
#
# These layers are CRails extensions — NOT part of the MCP wire oracle
# (documented deviation): the official SDK has no key/scope/quota
# concepts, so the bodies here are our own JSON-RPC -32001/-32002/-32003
# errors.

require "spec"
require "http"
require "../src/action_mcp_cr"

class WriteTool
  include ActiveAgent::Tool

  ActionMCP.mcp_scope :write

  description "Mutates data"
  input payload : String

  def call : ActiveAgent::ToolResult
    ActiveAgent::ToolResult.ok("wrote:#{payload}")
  end
end

class Echo2Tool
  include ActiveAgent::Tool
  description "Echo"
  input message : String

  def call : ActiveAgent::ToolResult
    ActiveAgent::ToolResult.ok(message)
  end
end

class GatewayMcp < ActionMCP::Server
  server_name "gw"
  server_version "9.9.9"
  tools Echo2Tool, WriteTool
end

# Agent-as-tool: scripted test provider, no network.
class OracleAgent < ActiveAgent::Base
  provider :test

  def self.build_provider : ActiveAgent::Provider
    ActiveAgent::Providers::Test.script do
      text "agent answer"
    end
  end
end

class AgentMcp < ActionMCP::Server
  server_name "agents"
  tools agent(OracleAgent, "Agent as a tool")
end

ActionMCP.mount = GatewayMcp

CALL_ECHO  = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo2_tool","arguments":{"message":"hi"}}})
CALL_WRITE = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"write_tool","arguments":{"payload":"x"}}})

private def post_mcp(body : String, *, token : String? = nil,
                     server : ActionMCP::Server.class = GatewayMcp,
                     accept : String? = "application/json") : String
  ActionMCP.mount = server
  headers = HTTP::Headers.new
  headers["Accept"] = accept unless accept.nil?
  headers["Content-Type"] = "application/json"
  headers["Authorization"] = "Bearer #{token}" if token
  request = HTTP::Request.new("POST", "/mcp", headers, body: IO::Memory.new(body))
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(request, response)
  controller = ActionMCP::ServerController.new(context)
  controller.__set_params({} of String => String)
  controller.__run_action("create")
  context.response.close
  "#{response.status_code}|#{io.to_s.split("\r\n\r\n", 2).last? || ""}"
end

# Configure the gateway (authenticator + optional quota on a fresh
# cache), run one POST, restore clean state.
private def with_gateway(body : String, *, token : String? = nil,
                         quota_limit : Int32? = nil,
                         accept : String? = "application/json") : String
  ActionMCP::Gateway.authenticator = ->(t : String) : ActionMCP::ApiKey? do
    case t
    when "tok-ro" then ActionMCP::ApiKey.new("ro-key", ["read"])
    when "tok-rw" then ActionMCP::ApiKey.new("rw-key")
    else
      nil
    end
  end
  ActionMCP::Gateway.quota_limit = quota_limit
  ActionMCP::Gateway.quota_within = 1.minute
  ActionMCP::Gateway.cache = ActiveSupport::Cache::MemoryStore.new
  post_mcp(body, token: token, accept: accept)
ensure
  ActionMCP::Gateway.authenticator = nil
  ActionMCP::Gateway.quota_limit = nil
  ActionMCP::Gateway.quota_within = nil
  ActionMCP::Gateway.cache = ActiveSupport::Cache::MemoryStore.new
end

describe "ActionMCP::Gateway" do
  it "401 without a token when an authenticator is configured" do
    with_gateway(CALL_ECHO).should start_with("401|")
  end

  it "401 on an unknown token (JSON-RPC -32001)" do
    with_gateway(CALL_ECHO, token: "nope")
      .should contain(%("code":-32001,"message":"Unauthorized"))
  end

  it "allows a valid key to call a read tool" do
    with_gateway(CALL_ECHO, token: "tok-rw").should start_with("200|")
  end

  it "403 when the key lacks the tool scope" do
    result = with_gateway(CALL_WRITE, token: "tok-ro")
    result.should start_with("403|")
    result.should contain("requires scope: write")
  end

  it "allows a full-scope key to call a write tool" do
    with_gateway(CALL_WRITE, token: "tok-rw").should start_with("200|")
  end

  it "429 (JSON-RPC -32003) when the quota is exhausted" do
    with_gateway(CALL_ECHO, token: "tok-rw", quota_limit: 1)
      .should start_with("200|")
    # Second request inside the fixed window: the counter persisted in
    # the gateway cache (shared across requests via the store).
    ActionMCP::Gateway.authenticator = ->(t : String) : ActionMCP::ApiKey? { ActionMCP::ApiKey.new("rw-key") }
    ActionMCP::Gateway.quota_limit = 1
    ActionMCP::Gateway.quota_within = 1.minute
    ActionMCP::Gateway.cache = ActiveSupport::Cache::MemoryStore.new
    post_mcp(CALL_ECHO, token: "tok-rw").should start_with("200|")
    result = post_mcp(CALL_ECHO, token: "tok-rw")
    result.should start_with("429|")
    result.should contain("-32003")
  ensure
    ActionMCP::Gateway.authenticator = nil
    ActionMCP::Gateway.quota_limit = nil
    ActionMCP::Gateway.quota_within = nil
    ActionMCP::Gateway.cache = ActiveSupport::Cache::MemoryStore.new
  end

  it "counts usage per key for billing (tools/call only)" do
    ActionMCP::Gateway.authenticator = ->(t : String) : ActionMCP::ApiKey? { ActionMCP::ApiKey.new("rw-key") }
    ActionMCP::Gateway.cache = ActiveSupport::Cache::MemoryStore.new
    post_mcp(CALL_ECHO, token: "tok-rw")
    post_mcp(CALL_ECHO, token: "tok-rw")
    post_mcp(CALL_WRITE, token: "tok-rw")
    post_mcp(%({"jsonrpc":"2.0","id":9,"method":"tools/list"}), token: "tok-rw") # not a call
    ActionMCP::Gateway.usage_for("rw-key").should eq(3)
  ensure
    ActionMCP::Gateway.authenticator = nil
    ActionMCP::Gateway.cache = ActiveSupport::Cache::MemoryStore.new
  end

  it "publishes an mcp.tools_call audit event" do
    events = [] of String
    ActiveSupport::Notifications.subscribe("mcp.tools_call") do |event|
      events << "#{event.payload["tool"]}:#{event.payload["key"]}:#{event.payload["is_error"]}"
    end
    begin
      with_gateway(CALL_ECHO, token: "tok-rw")
      with_gateway(CALL_WRITE, token: "tok-ro") # 403 — no event
    ensure
      ActiveSupport::Notifications.clear
    end
    events.should eq(["echo2_tool:rw-key:false"])
  end

  it "406 guard still applies with auth configured" do
    with_gateway(CALL_ECHO, token: "tok-rw", accept: nil)
      .should start_with("406|")
  end
end

describe "ActionMCP::Server DSL" do
  it "exposes an agent as a tool with a prompt input" do
    body = post_mcp(%({"jsonrpc":"2.0","id":1,"method":"tools/list"}), server: AgentMcp)
    body.should contain(%("name":"oracle_agent"))
    body.should contain(%("description":"Agent as a tool"))
    body.should contain(%({"prompt":{"type":"string"}}))
  end

  it "runs the agent loop on tools/call" do
    body = post_mcp(
      %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"oracle_agent","arguments":{"prompt":"hi"}}}),
      server: AgentMcp)
    body.should contain("agent answer")
    body.should contain(%("isError":false))
  end

  it "validates the prompt like any other required argument" do
    body = post_mcp(
      %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"oracle_agent","arguments":{}}}),
      server: AgentMcp)
    body.should contain("Missing required arguments: prompt")
  end
end

describe "CRails::Routes drawer" do
  it "mcp draws POST/GET/DELETE to action_mcp/server" do
    set = CRails::Routes::RouteSet.new
    set.draw { mcp "/mcp" }
    routes = set.routes.map { |r| "#{r.verb}|#{r.pattern}|#{r.controller}##{r.action}" }
    routes.should contain("POST|/mcp|action_mcp/server#create")
    routes.should contain("GET|/mcp|action_mcp/server#show")
    routes.should contain("DELETE|/mcp|action_mcp/server#destroy")
    ActionController::Dispatch.resolve("action_mcp/server")
      .should eq(ActionMCP::ServerController)
  end
end
