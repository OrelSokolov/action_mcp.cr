# ActionMCP::Gateway — the monetization layer around the MCP endpoint
# (Iteration 18): API/service keys with read/write scopes, quotas, usage
# accounting for billing, per-call audit. CRails extension — NOT part of
# the MCP wire oracle (the Ruby SDK has no equivalent; documented as a
# deviation in PLAN.md).
#
# Configuration (config/initializers/mcp.cr):
#
#   ActionMCP.authenticate do |token|                     # Bearer token → key
#     MyApp::ApiKeys.verify(token)                         # your JWT/DB lookup
#   end                                                    # → ApiKey or nil
#   ActionMCP.quota_limit = 10_000
#   ActionMCP.quota_within = 24.hours
#   ActionMCP.cache = ActiveSupport::Cache.lookup_store(:memory_store)
#
# Effects on POST /mcp:
#   * authenticator configured → every request needs a valid
#     `Authorization: Bearer <token>`, else 401 (JSON-RPC -32001);
#   * tools/call on a tool whose `mcp_scope` the key lacks → 403
#     (JSON-RPC -32002);
#   * requests past quota_limit per key within the window → 429
#     (JSON-RPC -32003) — Cache#increment fixed window (the rate_limit
#     semantics of Iteration 12);
#   * every successful tools/call increments `mcp:usage:<identity>` in
#     the cache (billing recurring job reads `usage_for`) and publishes
#     an ActiveSupport::Notifications "mcp.tools_call" audit event.

module ActionMCP
  # An authenticated API/service key. `scopes` names the tool scopes the
  # key may call (default: both read and write).
  class ApiKey
    getter identity : String
    getter scopes : Array(String)

    def initialize(@identity : String, @scopes = ["read", "write"])
    end
  end

  module Gateway
    class_property authenticator : Proc(String, ApiKey?)?

    class_property cache : ActiveSupport::Cache::Store =
      ActiveSupport::Cache::MemoryStore.new

    class_property quota_limit : Int32? = nil
    class_property quota_within : Time::Span? = nil

    # Bearer token from the request, or nil.
    def self.bearer_token(request : HTTP::Request) : String?
      header = request.headers["Authorization"]?
      return nil unless header
      return nil unless header.starts_with?("Bearer ")
      header[7..].strip
    end

    # Authenticate the request; nil result → the controller writes 401.
    def self.authenticate(request : HTTP::Request) : ApiKey?
      auth = authenticator
      return nil unless auth
      token = bearer_token(request)
      return nil unless token
      auth.call(token)
    end

    def self.auth_required? : Bool
      !authenticator.nil?
    end

    # Quota check (fixed window from the first request — Cache#increment
    # keeps the entry's original expiry). True → over quota.
    def self.quota_exceeded?(key : ApiKey) : Bool
      limit = quota_limit
      return false unless limit
      count = cache.increment("mcp:quota:#{key.identity}", 1,
        expires_in: quota_within)
      !count.nil? && count > limit
    end

    def self.count_usage(key : ApiKey) : Nil
      cache.increment("mcp:usage:#{key.identity}", 1)
    end

    # Usage counter for a key identity — the billing recurring job's input.
    def self.usage_for(identity : String) : Int32
      cache.read("mcp:usage:#{identity}").try(&.to_i) || 0
    end
  end
end
