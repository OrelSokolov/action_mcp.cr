# action_mcp_cr — приложение как MCP-сервер

Итерация 18 корневого плана: приложение экспонирует свои
`ActiveAgent::Tool` наружу по Model Context Protocol (Streamable HTTP
`/mcp`, JSON-RPC 2.0: initialize / tools list / call). Общий знаменатель
с агентами — один контракт Tool; MCP-клиент (consuming, McpToolSource)
остаётся в active_agent P2 — exposing и consuming в разных шардах.

Монетизация по ключам: Bearer-токены → ApiKey со скоупами read/write,
квоты (Cache#increment, фиксированное окно — семантика rate_limit
Iteration 12), учёт вызовов → счётчик `mcp:usage:<identity>` для
биллинговой recurring-джобы, аудит каждого tools/call событием
`mcp.tools_call` (Notifications).

## Oracle (AGENTS.md: oracle-first)

Оригинал — ОФИЦИАЛЬНЫЙ Ruby SDK `mcp` 1.7.0 (modelcontextprotocol/
ruby-sdk), вендорен в `oracle/vendor/gems`. Режим — StreamableHTTPTransport
stateless + JSON response (тот же режим монтирует и наш порт):
`oracle/cases.rb` гоняет транспорт под Rack::MockRequest →
`oracle/expected.yml` (28 кейсов, детерминированные, формат
`case_id\tstatus|content-type|body`). Зеркало `spec/oracle_spec.cr`
(28/28) прогоняет те же кейсы через `ActionMCP::ServerController`
(полный dispatch action_pack) — байты байт-в-байт, включая порядок
ключей inputSchema ($schema, properties, required, type), echo id
(число/строка), сообщения json_schemer-стиля
("Invalid arguments: value at `/times` is not an integer").

Кейсы: initialize (echo/negotiation/unknown→latest-stable/без params),
нотификации → 202, ping (+string id), tools/list, tools/call
(ok/raise→-32603/unknown→-32602/missing required→isError/wrong type),
resources/prompts стабы, method not found → -32601, parse error → 400
-32700, batch-массив → -32600, Accept → 406, Content-Type → 415,
GET → 405, DELETE → 200 {"success":true}.

## Использование

    # config/mcp.cr
    class AppMcp < ActionMCP::Server
      server_name "myapp"
      server_version "1.0.0"
      tools CustomerSearch, CreateDeal,          # ActiveAgent::Tool классы
            agent(SupportAgent, "CRM оператор")  # агент как инструмент
    end
    ActionMCP.mount = AppMcp
    ActionMCP.authenticate { |token| ApiKeys.verify(token) }  # опц.
    ActionMCP.quota_limit = 10_000; ActionMCP.quota_within = 24.hours

    # config/routes.cr
    mcp "/mcp"

Скоуп тула: `ActionMCP.mcp_scope :write` в теле класса тула (дефолт
:read — шов объявлен в `ActiveAgent::Tool.included`, см. PLAN
active_agent). Ключ без скоупа → 403 (JSON-RPC -32002).

## Структура

- `src/protocol.cr` — JSON-RPC 2.0 + MCP wire (байты из оракула),
  гварды Accept/Content-Type, negotiation версий, валидация аргументов.
- `src/server.cr` — `ActionMCP::Server` DSL: `tools`-макрос
  (compile-time диспетчер по образцу ActiveAgent::Base), `agent(...)`
  генерирует wrapper-тул (input `prompt : String`, `.ask`, wire-имя =
  underscore имени агента).
- `src/gateway.cr` — ApiKey, authenticate-хук, квоты, usage-счётчик
  (`usage_for` — вход биллинговой recurring-джобы), аудит.
- `src/controller.cr` — `ActionMCP::ServerController` (dispatch-ключ
  "action_mcp/server") + `Drawer#mcp` (POST/GET/DELETE).

## Статус

- [x] P0 (2026-10-06): oracle 28 кейсов + зеркало 28/28, гейтвей/DSL/
      роуты 13/13 — сюита 41/41; соседи зелёные (active_agent 21/21,
      action_pack 153/153, railties 309/309). По пути: латентный баг
      `ActiveAgent::Tool#input` (пустой список полей — `[ ]` без типа)
      и re-feed raw body в `__merge_body_params` (action_pack: тело
      JSON-запроса съедалось param-merge до контроллера + битый JSON
      валидировался раньше экшена).

## Отклонения от SDK (задокументированы)

- Только стабильный legacy-lifecycle: stateless, JSON-response режим
  (без SSE-стримов, сессий и SEP-2575 modern envelope; GET всегда 405).
- Гейтвей (401/403/429, коды -32001/-32002/-32003) — расширение CRails,
  оракулом не покрыто (у SDK нет ключей/квот).
- `logging/setLevel`, `completion/*`, server-to-client requests
  (sampling/elicitation/roots) — не реализованы (answer: -32601).
- tools/list не фильтруется по скоупу ключа (клиент видит весь каталог,
  гейт на tools/call).
- initialize-валидация отдельных полей (protocolVersion/capabilities/
  clientInfo) отвечает общим -32602 "Invalid params" (оракулом заперт
  только кейс полного отсутствия params).

## P1/P2

- P1: `crails new` генератор mcp-конфига; биллинг-recurring-джоба
  (снимок usage → счёт); метрики квот в /metrics.
- P2: SSE-режим ответов (MAY по спецификации), MCP-клиент
  (McpToolSource) в active_agent.
