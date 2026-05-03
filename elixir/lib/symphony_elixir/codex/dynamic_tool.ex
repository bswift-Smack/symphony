defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Linear.Client, LocalBoard}

  @linear_graphql_tool "linear_graphql"
  @local_board_tool "local_board"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @local_board_description """
  Update the local Symphony board by moving cards or appending workpad comments.
  """

  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @local_board_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["action"],
    "properties" => %{
      "action" => %{
        "type" => "string",
        "enum" => ["move_card", "add_comment"],
        "description" => "The local board operation to perform."
      },
      "card_id" => %{
        "type" => ["string", "null"],
        "description" => "The local board card id."
      },
      "state" => %{
        "type" => ["string", "null"],
        "description" => "Target state for move_card."
      },
      "body" => %{
        "type" => ["string", "null"],
        "description" => "Comment body for add_comment."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @local_board_tool ->
        execute_local_board(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @local_board_tool,
        "description" => @local_board_description,
        "inputSchema" => @local_board_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_local_board(arguments, opts) do
    custom_local_board_client = Keyword.get(opts, :local_board_client)
    local_board_client = custom_local_board_client || (&execute_local_board_action/2)

    context_resolver =
      Keyword.get(opts, :local_board_context_resolver) ||
        if is_nil(custom_local_board_client), do: &LocalBoard.resolve_card_context/1, else: nil

    with {:ok, action, normalized_arguments} <- normalize_local_board_arguments(arguments),
         {:ok, normalized_arguments} <- put_local_board_context(normalized_arguments, context_resolver),
         :ok <- local_board_client.(action, normalized_arguments) do
      dynamic_tool_response(true, encode_payload(%{"ok" => true}))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_local_board_arguments(arguments) when is_map(arguments) do
    case normalized_string(Map.get(arguments, "action") || Map.get(arguments, :action)) do
      "move_card" ->
        normalize_local_board_move(arguments)

      "add_comment" ->
        normalize_local_board_comment(arguments)

      action when is_binary(action) ->
        {:error, {:unsupported_local_board_action, action}}

      _ ->
        {:error, :missing_local_board_action}
    end
  end

  defp normalize_local_board_arguments(_arguments), do: {:error, :invalid_local_board_arguments}

  defp normalize_local_board_move(arguments) do
    card_id = normalized_string(Map.get(arguments, "card_id") || Map.get(arguments, :card_id))
    state = normalized_string(Map.get(arguments, "state") || Map.get(arguments, :state))

    if is_binary(card_id) and is_binary(state) do
      {:ok, :move_card, %{"card_id" => card_id, "state" => state}}
    else
      {:error, :invalid_local_board_move}
    end
  end

  defp normalize_local_board_comment(arguments) do
    card_id = normalized_string(Map.get(arguments, "card_id") || Map.get(arguments, :card_id))
    body = normalized_string(Map.get(arguments, "body") || Map.get(arguments, :body))

    if is_binary(card_id) and is_binary(body) do
      {:ok, :add_comment, %{"card_id" => card_id, "body" => body}}
    else
      {:error, :invalid_local_board_comment}
    end
  end

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_string(_value), do: nil

  defp put_local_board_context(%{"card_id" => card_id} = arguments, context_resolver)
       when is_binary(card_id) and is_function(context_resolver, 1) do
    case context_resolver.(card_id) do
      {:ok, context} when is_map(context) ->
        {:ok,
         arguments
         |> Map.put("board_slug", Map.get(context, :board_slug) || Map.get(context, "board_slug"))
         |> Map.put("project", Map.get(context, :project) || Map.get(context, "project"))}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_local_board_context, other}}
    end
  end

  defp put_local_board_context(arguments, _context_resolver), do: {:ok, arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_local_board_action) do
    %{
      "error" => %{
        "message" => "`local_board` requires an action of `move_card` or `add_comment`."
      }
    }
  end

  defp tool_error_payload(:invalid_local_board_arguments) do
    %{
      "error" => %{
        "message" => "`local_board` expects an object with an `action` field."
      }
    }
  end

  defp tool_error_payload(:invalid_local_board_move) do
    %{
      "error" => %{
        "message" => "`local_board` move_card requires non-empty `card_id` and `state` strings."
      }
    }
  end

  defp tool_error_payload(:invalid_local_board_comment) do
    %{
      "error" => %{
        "message" => "`local_board` add_comment requires non-empty `card_id` and `body` strings."
      }
    }
  end

  defp tool_error_payload({:unsupported_local_board_action, action}) do
    %{
      "error" => %{
        "message" => "Unsupported local board action: #{inspect(action)}.",
        "supportedActions" => ["move_card", "add_comment"]
      }
    }
  end

  defp tool_error_payload({:local_board_action_failed, action, reason}) do
    %{
      "error" => %{
        "message" => "Local board action failed.",
        "action" => to_string(action),
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:local_board_card_not_found, card_id}) do
    %{
      "error" => %{
        "message" => "Local board card was not found.",
        "card_id" => card_id
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp execute_local_board_action(:move_card, %{"card_id" => card_id, "state" => state} = arguments) do
    case LocalBoard.move_card(card_id, state, local_board_project_context(arguments)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:local_board_action_failed, :move_card, reason}}
    end
  end

  defp execute_local_board_action(:add_comment, %{"card_id" => card_id, "body" => body} = arguments) do
    case LocalBoard.add_comment(card_id, body, local_board_project_context(arguments)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:local_board_action_failed, :add_comment, reason}}
    end
  end

  defp local_board_project_context(%{"project" => project}) when is_map(project), do: project
  defp local_board_project_context(_arguments), do: nil
end
