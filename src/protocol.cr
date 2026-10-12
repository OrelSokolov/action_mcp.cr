# JSON-RPC 2.0 + MCP wire protocol (stateless Streamable HTTP, JSON
# response mode) — byte-mirrored from the official MCP Ruby SDK 1.7.0
# (gem "mcp", oracle/expected.yml, 29 cases).
#
# Envelope shapes locked by the oracle:
#   result : {"jsonrpc":"2.0","id":<echo>,"result":<payload>}
#   dispatch error : {...,"error":{"code":C,"message":M,"data":D}}
#   transport-guard errors (406/415/400/405) carry NO "data" member
#   tools/list tool: {"name":..,"description":..,"inputSchema":{
#     "$schema":"https://json-schema.org/draft/2020-12/schema",
#     "properties":{..},"required":[..],"type":"object"}}
#   tools/call ok: {"content":[{"type":"text","text":..}],"isError":false}
#   notification (no "id"): HTTP 202, empty body, no Content-Type.
#
# Error codes: -32700 parse, -32600 invalid request, -32601 method not
# found, -32602 invalid params, -32603 internal. Version negotiation:
# echo the client's version when supported, else the latest stable
# handshake version (SDK behaviour on unknown versions).

module ActionMCP
  struct RpcResponse
    getter status : Int32
    getter content_type : String? # nil → no Content-Type header (202)
    getter body : String

    def initialize(@status, @body, @content_type = "application/json")
    end

    def self.accepted : RpcResponse
      new(202, "", content_type: nil)
    end
  end

  module Protocol
    PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    LATEST_VERSION    = "2025-11-25"
    SCHEMA_URI        = "https://json-schema.org/draft/2020-12/schema"

    # --- JSON-RPC envelope building (field order locked by the oracle) ---

    def self.write_id(io : IO, id : JSON::Any?) : Nil
      if id
        id.to_json(io)
      else
        io << "null"
      end
    end

    def self.result(id : JSON::Any?, result_json : String) : String
      String.build do |s|
        s << %({"jsonrpc":"2.0","id":)
        write_id(s, id)
        s << %(,"result":) << result_json << "}"
      end
    end

    # Dispatch-level JSON-RPC error (carries "data").
    def self.error(id : JSON::Any?, code : Int32, message : String, data : String) : String
      String.build do |s|
        s << %({"jsonrpc":"2.0","id":)
        write_id(s, id)
        s << %(,"error":{"code":) << code
        s << %(,"message":) << message.to_json
        s << %(,"data":) << data.to_json << "}}"
      end
    end

    # Transport-guard error (no "data" member — oracle: accept_missing,
    # content_type_wrong, parse_error, batch_rejected, get_405).
    def self.guard_body(code : Int32, message : String) : String
      %({"jsonrpc":"2.0","id":null,"error":{"code":) + code.to_s +
        %(,"message":) + message.to_json + "}}"
    end

    def self.guard(status : Int32, code : Int32, message : String) : RpcResponse
      RpcResponse.new(status, guard_body(code, message))
    end

    # --- transport guards (order: Accept, then Content-Type — as the SDK) ---

    def self.accept_ok?(accept : String?) : Bool
      return false unless accept
      accept.split(',').any? do |entry|
        type = entry.split(';').first.strip
        type == "*/*" || type == "application/json"
      end
    end

    def self.content_type_ok?(ct : String?) : Bool
      return false unless ct
      ct.split(';').first.strip == "application/json"
    end

    def self.not_acceptable : RpcResponse
      guard(406, -32600,
        "Not Acceptable: Accept header must include application/json")
    end

    def self.unsupported_media_type : RpcResponse
      guard(415, -32600,
        "Unsupported Media Type: Content-Type must be application/json")
    end

    # --- request handling ----------------------------------------------------

    # POST body → RpcResponse. `server` is the mounted ActionMCP::Server
    # subclass; `key` is the authenticated ApiKey (nil in open mode).
    # Notification bodies (no "id") are accepted with 202 before dispatch.
    def self.handle_post(server : ActionMCP::Server.class, body : String,
                         key : ApiKey?) : RpcResponse
      payload = JSON.parse(body)
      unless payload.as_h?
        return guard(400, -32600,
          "Invalid Request: JSON-RPC body must be a single request object")
      end
      return RpcResponse.accepted unless payload["id"]?
      dispatch(server, payload, key)
    rescue JSON::ParseException
      guard(400, -32700, "Parse error: Invalid JSON")
    end

    def self.dispatch(server : ActionMCP::Server.class, payload : JSON::Any,
                      key : ApiKey?) : RpcResponse
      id = payload["id"]?
      method = payload["method"]?.try(&.as_s?)

      case method
      when "initialize"     then RpcResponse.new(200, initialize_result(server, id, payload["params"]?))
      when "ping"           then RpcResponse.new(200, result(id, "{}"))
      when "tools/list"     then RpcResponse.new(200, result(id, tools_list_json(server)))
      when "tools/call"     then tools_call(server, id, payload["params"]?, key)
      when "resources/list" then RpcResponse.new(200, result(id, %({"resources":[]})))
      when "resources/read" then RpcResponse.new(200, result(id, %({"contents":[]})))
      when "prompts/list"   then RpcResponse.new(200, result(id, %({"prompts":[]})))
      else
        RpcResponse.new(200, error(id, -32601, "Method not found", method.to_s))
      end
    end

    def self.initialize_result(server : ActionMCP::Server.class, id : JSON::Any?,
                               params : JSON::Any?) : String
      h = params.try(&.as_h?)
      version = h.try { |hh| hh["protocolVersion"]?.try(&.as_s?) }
      caps = h.try { |hh| hh["capabilities"]? }.try(&.as_h?)
      client = h.try { |hh| hh["clientInfo"]? }.try(&.as_h?)
      if version.nil? || caps.nil? || client.nil?
        return error(id, -32602, "Invalid params", "Invalid params")
      end
      negotiated = PROTOCOL_VERSIONS.includes?(version) ? version : LATEST_VERSION
      result(id, String.build do |s|
        s << %({"protocolVersion":) << negotiated.to_json
        s << %(,"capabilities":{"tools":{"listChanged":true},)
        s << %("prompts":{"listChanged":true},"resources":{"listChanged":true},"logging":{}})
        s << %(,"serverInfo":{"name":) << server.__server_name.to_json
        s << %(,"version":) << server.__server_version.to_json << "}}"
      end)
    end

    def self.tools_list_json(server : ActionMCP::Server.class) : String
      String.build do |s|
        s << %({"tools":[)
        server.__tool_metas.each_with_index do |meta, i|
          s << "," if i > 0
          s << %({"name":) << meta.name.to_json
          s << %(,"description":) << meta.description.to_json
          s << %(,"inputSchema":{"$schema":) << SCHEMA_URI.to_json
          s << %(,"properties":) << (meta.schema["properties"]? || JSON::Any.new({} of String => JSON::Any)).to_json
          s << %(,"required":) << (meta.schema["required"]? || JSON::Any.new([] of JSON::Any)).to_json
          s << %(,"type":"object"}})
        end
        s << "]}"
      end
    end

    # --- tools/call ----------------------------------------------------------

    def self.tools_call(server : ActionMCP::Server.class, id : JSON::Any?,
                        params : JSON::Any?, key : ApiKey?) : RpcResponse
      h = params.try(&.as_h?)
      return RpcResponse.new(200, error(id, -32602, "Invalid params", "Invalid params")) unless h
      name = h["name"]?.try(&.as_s?)
      return RpcResponse.new(200, error(id, -32602, "Invalid params", "Missing tool name")) unless name

      unless server.__tool_names.includes?(name)
        return RpcResponse.new(200, error(id, -32602, "Invalid params", "Tool not found: #{name}"))
      end

      # Scope gate (CRails monetization layer — not part of the MCP oracle).
      scope = server.__scope_for(name)
      if key && !key.scopes.includes?(scope.to_s)
        return RpcResponse.new(403,
          error(id, -32002, "Forbidden", "tool #{name} requires scope: #{scope}"))
      end

      args = h["arguments"]?.try(&.as_h?) || {} of String => JSON::Any
      if bad = validate_arguments(server, name, args)
        return RpcResponse.new(200, content_text(id, bad, is_error: true))
      end

      tool_result = server.__execute_tool(name, JSON::Any.new(args))
      ActiveSupport::Notifications.instrument(
        "mcp.tools_call",
        {"tool" => name, "key" => key.try(&.identity).to_s,
         "is_error" => (!tool_result.ok).to_s} of String => ActiveSupport::Any
      ) { nil }
      Gateway.count_usage(key) if key

      RpcResponse.new(200, content_text(id, tool_result.content, is_error: !tool_result.ok))
    rescue e : Exception
      RpcResponse.new(200, error(id, -32603, "Internal error", "Internal error calling tool #{name}"))
    end

    private def self.content_text(id : JSON::Any?, text : String, is_error : Bool) : String
      result(id, %({"content":[{"type":"text","text":#{text.to_json}}],"isError":#{is_error}}))
    end

    TYPE_WORDS = {"String" => "a string", "String?" => "a string",
                  "Int32" => "an integer", "Int32?" => "an integer",
                  "Int64" => "an integer", "Int64?" => "an integer",
                  "Float64" => "a number", "Float64?" => "a number",
                  "Bool" => "a boolean", "Bool?" => "a boolean",
                  "Array(String)" => "an array", "Array(String)?" => "an array"}

    # SDK-style argument validation messages (oracle: call_missing_required,
    # call_wrong_type_int, call_wrong_type_string). Returns nil when valid.
    def self.validate_arguments(server : ActionMCP::Server.class, name : String,
                                args : Hash(String, JSON::Any)) : String?
      missing = [] of String
      server.__fields_for(name).each do |(fname, type, optional)|
        value = args[fname]?
        if value.nil?
          missing << fname unless optional
        elsif !value_matches?(type, value)
          return "Invalid arguments: value at `/#{fname}` is not #{TYPE_WORDS[type]}"
        end
      end
      "Missing required arguments: #{missing.join(", ")}" unless missing.empty?
    end

    def self.value_matches?(type : String, value : JSON::Any) : Bool
      matches = case type
                when "String", "String?"                   then !value.as_s?.nil?
                when "Int32", "Int32?", "Int64", "Int64?"  then !value.as_i?.nil?
                when "Float64", "Float64?"                 then !value.as_f?.nil? || !value.as_i?.nil?
                when "Bool", "Bool?"                       then !value.as_bool?.nil?
                when "Array(String)", "Array(String)?"     then value.as_a?.try(&.all?(&.as_s?)) || false
                else                                            false
                end
      matches ? true : false
    end
  end
end
