defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the dynamic tool input contracts" do
    tool_specs = DynamicTool.tool_specs()

    assert %{
             "description" => description,
             "inputSchema" => %{
               "properties" => %{
                 "query" => _,
                 "variables" => _
               },
               "required" => ["query"],
               "type" => "object"
             },
             "name" => "linear_graphql"
           } = Enum.find(tool_specs, &(&1["name"] == "linear_graphql"))

    assert description =~ "Linear"

    assert %{
             "description" => board_description,
             "inputSchema" => %{
               "properties" => %{
                 "action" => _,
                 "body" => _,
                 "card_id" => _,
                 "state" => _
               },
               "required" => ["action"],
               "type" => "object"
             },
             "name" => "local_board"
           } = Enum.find(tool_specs, &(&1["name"] == "local_board"))

    assert board_description =~ "local Symphony board"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "local_board"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "local_board moves cards and adds comments through the board client" do
    test_pid = self()

    move_response =
      DynamicTool.execute(
        "local_board",
        %{"action" => "move_card", "card_id" => "card-1", "state" => "Running"},
        local_board_client: fn action, args ->
          send(test_pid, {:local_board_client_called, action, args})
          :ok
        end
      )

    assert_received {:local_board_client_called, :move_card, %{"card_id" => "card-1", "state" => "Running"}}
    assert move_response["success"] == true
    assert Jason.decode!(move_response["output"]) == %{"ok" => true}

    comment_response =
      DynamicTool.execute(
        "local_board",
        %{"action" => "add_comment", "card_id" => "card-1", "body" => "## Codex Workpad\n- [x] planned"},
        local_board_client: fn action, args ->
          send(test_pid, {:local_board_client_called, action, args})
          :ok
        end
      )

    assert_received {:local_board_client_called, :add_comment, %{"body" => "## Codex Workpad\n- [x] planned", "card_id" => "card-1"}}
    assert comment_response["success"] == true
  end

  test "local_board resolves project context from the card before moves and comments" do
    test_pid = self()

    move_response =
      DynamicTool.execute(
        "local_board",
        %{"action" => "move_card", "card_id" => "card-project-b", "state" => "Running"},
        local_board_client: fn action, args ->
          send(test_pid, {:local_board_client_called, action, args})
          :ok
        end,
        local_board_context_resolver: fn "card-project-b" ->
          {:ok,
           %{
             board_slug: "project-b",
             project: %{
               slug: "project-b",
               name: "Project B",
               directory: "/tmp/project-b"
             }
           }}
        end
      )

    assert move_response["success"] == true

    assert_received {:local_board_client_called, :move_card,
                     %{
                       "card_id" => "card-project-b",
                       "state" => "Running",
                       "board_slug" => "project-b",
                       "project" => %{
                         slug: "project-b",
                         name: "Project B",
                         directory: "/tmp/project-b"
                       }
                     }}

    comment_response =
      DynamicTool.execute(
        "local_board",
        %{"action" => "add_comment", "card_id" => "card-project-b", "body" => "proof"},
        local_board_client: fn action, args ->
          send(test_pid, {:local_board_client_called, action, args})
          :ok
        end,
        local_board_context_resolver: fn "card-project-b" ->
          {:ok,
           %{
             board_slug: "project-b",
             project: %{
               slug: "project-b",
               name: "Project B",
               directory: "/tmp/project-b"
             }
           }}
        end
      )

    assert comment_response["success"] == true

    assert_received {:local_board_client_called, :add_comment,
                     %{
                       "body" => "proof",
                       "card_id" => "card-project-b",
                       "board_slug" => "project-b",
                       "project" => %{
                         slug: "project-b",
                         name: "Project B",
                         directory: "/tmp/project-b"
                       }
                     }}
  end

  test "local_board validates required action arguments" do
    missing_state =
      DynamicTool.execute(
        "local_board",
        %{"action" => "move_card", "card_id" => "card-1"},
        local_board_client: fn _action, _args -> flunk("local board client should not be called") end
      )

    assert missing_state["success"] == false

    assert Jason.decode!(missing_state["output"]) == %{
             "error" => %{
               "message" => "`local_board` move_card requires non-empty `card_id` and `state` strings."
             }
           }

    unsupported =
      DynamicTool.execute(
        "local_board",
        %{"action" => "delete_card", "card_id" => "card-1"},
        local_board_client: fn _action, _args -> flunk("local board client should not be called") end
      )

    assert unsupported["success"] == false
    assert Jason.decode!(unsupported["output"])["error"]["message"] =~ "Unsupported local board action"
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end
end
