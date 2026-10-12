# ActionMCP::Server — the MCP endpoint of the application. Declare a
# subclass in config (one server per app, mounted via `ActionMCP.mount=`),
# expose the same ActiveAgent::Tool contract the app's own agents use —
# the LLM-facing surface and the MCP-facing surface stay one contract
# (Iteration 18: "общий знаменатель — контракт Tool"):
#
#   class AppMcp < ActionMCP::Server
#     server_name "myapp"
#     server_version "1.0.0"
#     tools CustomerSearch, CreateDeal,          # ActiveAgent::Tool classes
#           agent(SupportAgent, "CRM support operator")  # agent as a tool
#   end
#
#   ActionMCP.mount = AppMcp                     # config, then in routes:
#   #   mcp "/mcp"   (Drawer — draws POST/GET/DELETE to the endpoint)
#
# Tool wire names come from ActiveAgent::Tool (`Oracle::CustomerSearch`
# → "customer_search"). A tool may declare its MCP scope with
# `ActionMCP.mcp_scope :write` inside the tool class (default :read) —
# keys without that scope get 403 on tools/call (see Gateway).
#
# `agent(AgentClass, "description")` inside `tools` generates a wrapper
# tool (input `prompt : String`) running the agent loop via `.ask` —
# "агент как MCP-инструмент". Wire name = agent class underscored
# (SupportAgent → "support_agent").

module ActionMCP
  # Declare inside an ActiveAgent::Tool class body:
  #   ActionMCP.mcp_scope :write
  macro mcp_scope(scope)
    def self.__mcp_scope : Symbol
      {{ scope }}
    end
  end

  abstract class Server
    macro server_name(name)
      def self.__server_name : String
        {{ name }}
      end
    end

    macro server_version(version)
      def self.__server_version : String
        {{ version }}
      end
    end

    def self.__server_name : String
      "crails"
    end

    def self.__server_version : String
      ::ActionMCP::VERSION
    end

    # tools Foo, Bar, agent(SupportAgent, "description") — the exposed
    # surface. Compile-time dispatch (the ActiveAgent::Base#tools
    # pattern): metas for tools/list, a case-dispatcher for tools/call,
    # scope lookup for the Gateway. No runtime reflection.
    macro tools(*entries)
      {% tool_names_m = [] of Nil %}
      {% for e in entries %}
        {% if e.is_a?(Call) && e.name.stringify == "agent" %}
          {% agent = e.args[0] %}
          {% desc = e.named_args && e.named_args[:description] ? e.named_args[:description] : e.args[1] %}
          {% raise "agent(...) needs a description: agent(SupportAgent, \"...\")" unless desc %}
          {% wrapper = (agent.stringify.split("::").last + "McpTool").id %}
          class ::{{ wrapper }}
            include ::ActiveAgent::Tool
            description {{ desc }}
            input prompt : String

            def self.tool_name : String
              {{ agent.stringify.split("::").last.underscore }}
            end

            def call : ::ActiveAgent::ToolResult
              ::ActiveAgent::ToolResult.ok({{ agent }}.ask(prompt).output.to_s)
            end
          end
          {% tool_names_m << wrapper %}
        {% elsif e.is_a?(Path) || e.is_a?(Generic) || e.is_a?(Const) %}
          {% tool_names_m << e.id %}
        {% else %}
          {% raise "tools: expected a Tool class or agent(AgentClass, \"description\"), got: #{e}" %}
        {% end %}
      {% end %}

      def self.__tool_metas : Array(::ActiveAgent::ToolMeta)
        [
          {% for k, i in tool_names_m %}
            ::ActiveAgent::ToolMeta.new(
              {{ k.id }}.tool_name, {{ k.id }}.__description, {{ k.id }}.schema),
          {% end %}
        ] of ::ActiveAgent::ToolMeta
      end

      def self.__tool_names : Array(String)
        __tool_metas.map(&.name)
      end

      # Tool (name, type-string, optional?) tuples — argument validation
      # mirrors the SDK's json_schemer messages (see Protocol).
      def self.__fields_for(name : String) : Array({String, String, Bool})
        case name
        {% for k in tool_names_m %}
        when {{ k.id }}.tool_name then {{ k.id }}.__fields
        {% end %}
        else
          [] of {String, String, Bool}
        end
      end

      def self.__execute_tool(name : String, args : ::JSON::Any) : ::ActiveAgent::ToolResult
        case name
        {% for k in tool_names_m %}
        when {{ k.id }}.tool_name
          {{ k.id }}.__build(args).call
        {% end %}
        else
          ::ActiveAgent::ToolResult.error("Tool not found: #{name}")
        end
      end

      def self.__scope_for(name : String) : Symbol
        case name
        {% for k in tool_names_m %}
        when {{ k.id }}.tool_name then {{ k.id }}.__mcp_scope
        {% end %}
        else
          :read
        end
      end
    end

    # Bare server (no `tools` call): empty but valid endpoint.
    def self.__tool_metas : Array(::ActiveAgent::ToolMeta)
      [] of ::ActiveAgent::ToolMeta
    end

    def self.__tool_names : Array(String)
      [] of String
    end

    def self.__fields_for(name : String) : Array({String, String, Bool})
      [] of {String, String, Bool}
    end

    def self.__execute_tool(name : String, args : ::JSON::Any) : ::ActiveAgent::ToolResult
      ::ActiveAgent::ToolResult.error("Tool not found: #{name}")
    end

    def self.__scope_for(name : String) : Symbol
      :read
    end
  end
end
