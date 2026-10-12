# action_mcp_cr — the application as an MCP server (Iteration 18):
# Streamable HTTP /mcp, JSON-RPC 2.0 (initialize / tools list / call),
# exposing the same ActiveAgent::Tool contract the app's agents use.
# Wire-mirrored to the official MCP Ruby SDK 1.7.0 (oracle/expected.yml).

require "json"
require "http"

require "active_support_cr"
require "action_pack_cr"
require "active_agent_cr"

require "./protocol"
require "./gateway"
require "./server"
require "./controller"

module ActionMCP
  VERSION = "0.1.0"

  # The mounted server class (ActionMCP::Server subclass declared in the
  # app's config). The controller dispatches here at runtime.
  class_property mount : ActionMCP::Server.class = ActionMCP::Server
end
