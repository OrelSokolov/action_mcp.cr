# action_mcp.cr

A Crystal port of the server side of the official **MCP Ruby SDK `mcp` 1.7.0**
(modelcontextprotocol/ruby-sdk) — it exposes a CRails application as a
Model Context Protocol server over the Streamable HTTP transport
(stateless, JSON-response mode): JSON-RPC 2.0 `initialize` / `tools/list` /
`tools/call` on `POST /mcp`. The exposed surface is the same
`ActiveAgent::Tool` contract the app's own agents use, plus an
`agent(...` wrapper that turns an `ActiveAgent::Base` agent into a tool.
On top of the wire protocol sits a CRails-only Gateway (Bearer-token API
keys with read/write scopes, fixed-window quotas, usage counters for
billing, per-call audit events) that has no SDK counterpart. Suite:
**28/28 wire oracle (byte-for-byte against the real SDK) + 13/13
gateway/DSL/routes** against mcp 1.7.0.

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

## Installation

```yaml
dependencies:
  action_mcp_cr:
    github: OrelSokolov/action_mcp.cr
```

```sh
shards install
```

Depends on `active_support.cr`, `action_pack.cr` and `active_agent.cr`.

## Usage

```crystal
class CustomerSearch
  include ActiveAgent::Tool
  description "Find customers by name"
  input query : String, limit : Int32?
  ActionMCP.mcp_scope :read                  # default; :write for mutations

  def call : ActiveAgent::ToolResult
    ActiveAgent::ToolResult.ok(Customer.where(name: query).to_json)
  end
end

# config/mcp.cr
class AppMcp < ActionMCP::Server
  server_name "myapp"
  server_version "1.0.0"
  tools CustomerSearch, CreateDeal,                # ActiveAgent::Tool classes
        agent(SupportAgent, "CRM support operator") # agent as a tool
end
ActionMCP.mount = AppMcp
ActionMCP.authenticate { |token| ApiKeys.verify(token) }   # optional
ActionMCP.quota_limit = 10_000
ActionMCP.quota_within = 24.hours

# config/routes.cr
CRails.application.routes.draw do
  mcp "/mcp"    # draws POST + GET + DELETE
end
```

## Feature comparison vs mcp 1.7.0 (ruby-sdk, StreamableHTTPTransport)

### JSON-RPC wire protocol

| Feature | Original (mcp) | Port (action_mcp.cr) | Status |
|---|---|---|---|
| `initialize` (echo id, version negotiation, unknown → latest-stable, missing params → -32602) | ✅ | Same, byte-for-byte | ✅ |
| Notifications → `202` (no body) | ✅ | Same | ✅ |
| `ping` (numeric and string id) | ✅ | Same | ✅ |
| `tools/list` with inputSchema ($schema/properties/required/type key order) | ✅ | Same | ✅ |
| `tools/call` (ok / tool raise → -32603 / unknown tool → -32602 / missing required → `isError` / wrong type with json_schemer-style message) | ✅ | Same | ✅ |
| Errors: method not found → -32601, parse error → 400 -32700, batch array → -32600 | ✅ | Same | ✅ |
| Transport guards: Accept → 406, Content-Type → 415, GET → 405, DELETE → `200 {"success":true}` | ✅ | Same | ✅ |
| Field-level `initialize` validation (protocolVersion/capabilities/clientInfo) | ✅ | Generic -32602 "Invalid params" | ⚠️ partial |
| `resources/*`, `prompts/*` methods | ✅ | Stub responses (empty catalogs) | ⚠️ partial |

### Sessions, streaming, transports

| Feature | Original (mcp) | Port (action_mcp.cr) | Status |
|---|---|---|---|
| Stateless JSON-response mode | ✅ | The only mode (what the oracle locked) | ✅ |
| SSE response streams on POST/GET | ✅ | Not implemented (P2) | ❌ |
| Sessions, `Mcp-Session-Id`, resumability | ✅ | Stateless only | ❌ |
| SEP-2575 modern request envelope | ✅ | Legacy lifecycle only | ❌ |
| stdio transport | ✅ | HTTP only | ❌ |
| `logging/setLevel`, `completion/*` | ✅ | -32601 | ❌ |
| Server-to-client requests (sampling/elicitation/roots) | ✅ | Not implemented | ❌ |
| MCP client (consuming side) | ✅ | P2 in active_agent (McpToolSource) | ❌ |

### CRails extensions (no SDK counterpart)

| Feature | Original (mcp) | Port (action_mcp.cr) | Status |
|---|---|---|---|
| Bearer-token auth (401, JSON-RPC -32001) | n/a | `ActionMCP.authenticate` hook | ✅ |
| Key scopes (403, -32002; gate on tools/call, not tools/list) | n/a | `ActionMCP.mcp_scope` per tool | ✅ |
| Quotas (429, -32003; Cache#increment fixed window) | n/a | `quota_limit` / `quota_within` | ✅ |
| Usage accounting + audit (`mcp:usage:<identity>`, `mcp.tools_call` notification) | n/a | `Gateway.usage_for` for billing jobs | ✅ |
| `tools agent(Agent, "desc")` wrapper, `mcp "/mcp"` route | n/a | Server DSL + routes drawer | ✅ |
| Billing recurring job, quota metrics in /metrics, `crails new` generator | n/a | Planned | ❌ (P1) |

## Deviations & Crystal-specific notes

- Only the stable legacy lifecycle: stateless, JSON-response mode — no SSE
  streams, no sessions, no SEP-2575 modern envelope; GET always 405.
- The Gateway (401/403/429, codes -32001/-32002/-32003) is a CRails
  extension; the SDK has no keys/quotas, so it is not oracle-covered.
- `logging/setLevel`, `completion/*` and server-to-client requests answer
  -32601 (not implemented).
- `tools/list` is not filtered by key scope — the client sees the full
  catalog; the gate is on `tools/call`.
- `initialize` validation of individual fields responds with a generic
  -32602 "Invalid params" (the oracle locks only the missing-params case).
- Tool dispatch is compile-time (`tools` macro, case-dispatcher by the
  ActiveAgent::Base pattern) — no runtime reflection in Crystal.

Full list with rationale: `PLAN.md` (Russian).

## Testing

```sh
crystal spec          # no external services; quotas use the in-memory cache
```

Oracle: 28 cases recorded with the real `mcp` 1.7.0 SDK
(`oracle/cases.rb` runs StreamableHTTPTransport stateless under
Rack::MockRequest → `oracle/expected.yml`); `spec/oracle_spec.cr` replays
them 1:1 through `ActionMCP::ServerController` — byte-for-byte bodies,
including inputSchema key order and json_schemer-style validation
messages. Gateway/DSL/routes: 13 unit specs. Vendored source of
reference: `oracle/vendor/gems/mcp-1.7.0/`.
