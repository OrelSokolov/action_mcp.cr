# The MCP endpoint controller + route. Mount with one line in the routes
# drawer:
#
#   CRails.application.routes.draw do
#     mcp "/mcp"
#   end
#
# The controller speaks the stateless Streamable HTTP transport in JSON
# mode (the SDK's `StreamableHTTPTransport.new(server, stateless: true,
# enable_json_response: true)` — the shape the oracle locked):
#   POST /mcp   → JSON-RPC handling (or 202 for notifications)
#   GET  /mcp   → 405 (no server-initiated streams in stateless mode)
#   DELETE /mcp → 200 {"success":true} (no sessions to drop)
#
# Guard order (SDK): Accept header → Content-Type → auth/quota (the
# CRails Gateway layer) → JSON-RPC parse/dispatch.

module ActionMCP
  class ServerController < ActionController::Base
    # POST /mcp
    def create
      unless Protocol.accept_ok?(request.headers["Accept"]?)
        return __write_rpc(Protocol.not_acceptable)
      end
      unless Protocol.content_type_ok?(request.headers["Content-Type"]?)
        return __write_rpc(Protocol.unsupported_media_type)
      end

      key = nil
      if Gateway.auth_required?
        key = Gateway.authenticate(request)
        unless key
          return __write_rpc(RpcResponse.new(401,
            Protocol.guard_body(-32001, "Unauthorized")))
        end
        if Gateway.quota_exceeded?(key)
          return __write_rpc(RpcResponse.new(429,
            Protocol.guard_body(-32003, "Quota exceeded")))
        end
      end

      server = ActionMCP.mount
      body = request.body.try(&.gets_to_end) || ""
      __write_rpc(Protocol.handle_post(server, body, key))
    end

    # GET /mcp — 405 in stateless mode (oracle: get_405).
    def show
      __write_rpc(Protocol.guard(405, -32600, "Method not allowed"))
    end

    # DELETE /mcp — 200 {"success":true} (oracle: delete_200).
    def destroy
      __write_rpc(RpcResponse.new(200, %({"success":true})))
    end

    private def __write_rpc(resp : RpcResponse) : Nil
      @performed = true
      response.status_code = resp.status
      if ct = resp.content_type
        response.headers["Content-Type"] = ct
      end
      response.print resp.body unless resp.body.empty?
    end
  end
end

class CRails::Routes::Drawer
  # `mcp "/mcp"` — mount the application's MCP server (POST + GET +
  # DELETE on the endpoint, dispatched to ActionMCP::ServerController —
  # key "action_mcp/server"). The mounted server class is set with
  # `ActionMCP.mount = AppMcp` (config/initializers/mcp.cr).
  def mcp(path : String = "/mcp") : Nil
    post path, to: "action_mcp/server#create", as: "mcp"
    get path, to: "action_mcp/server#show"
    delete path, to: "action_mcp/server#destroy"
  end
end
