defmodule SymphonyElixir.LocalBoard.Store do
  @moduledoc """
  Postgres persistence for the local Symphony board.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @project_table "symphony_projects"
  @card_table "symphony_board_cards"
  @comment_table "symphony_board_comments"
  @dependency_table "symphony_board_dependencies"
  @project_columns "slug, name, directory, repo_url, workspace_root, enabled, created_at, updated_at"
  @project_keys [:slug, :name, :directory, :repo_url, :workspace_root, :enabled, :created_at, :updated_at]

  @spec list_cards(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def list_cards(opts) when is_list(opts) do
    query_cards(card_query("WHERE c.board_slug = $1", "c.position ASC, c.created_at ASC, c.identifier ASC"), [board_slug(opts)], opts)
  end

  @spec list_projects(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_projects(opts) when is_list(opts) do
    query_projects(
      "SELECT #{@project_columns} FROM #{@project_table} ORDER BY enabled DESC, name ASC, slug ASC",
      [],
      opts
    )
  end

  @spec get_project(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_project(slug, opts) when is_binary(slug) and is_list(opts) do
    slug = String.trim(slug)

    with :ok <- validate_project_slug(slug) do
      query_project("SELECT #{@project_columns} FROM #{@project_table} WHERE slug = $1", [slug], opts)
    end
  end

  @spec create_project(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_project(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, project} <- project_attrs(attrs, opts) do
      query_project(
        "INSERT INTO #{@project_table} (slug, name, directory, repo_url, workspace_root) VALUES ($1, $2, $3, $4, $5) RETURNING #{@project_columns}",
        [project.slug, project.name, project.directory, project.repo_url, project.workspace_root],
        opts
      )
    end
  end

  @spec update_project(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_project(slug, attrs, opts) when is_binary(slug) and is_map(attrs) and is_list(opts) do
    slug = String.trim(slug)

    with :ok <- validate_project_slug(slug) do
      query_project(
        "UPDATE #{@project_table} SET name = COALESCE($2, name), directory = COALESCE($3, directory), repo_url = COALESCE($4, repo_url), workspace_root = COALESCE($5, workspace_root), enabled = COALESCE($6, enabled), updated_at = now() WHERE slug = $1 RETURNING #{@project_columns}",
        [
          slug,
          optional_string(attrs[:name] || attrs["name"]),
          optional_string(attrs[:directory] || attrs["directory"]),
          optional_string(attrs[:repo_url] || attrs["repo_url"]),
          optional_string(attrs[:workspace_root] || attrs["workspace_root"]),
          optional_boolean(attrs[:enabled] || attrs["enabled"])
        ],
        opts
      )
    end
  end

  @spec disable_project(String.t(), keyword()) :: :ok | {:error, term()}
  def disable_project(slug, opts) when is_binary(slug) and is_list(opts) do
    slug = String.trim(slug)

    with :ok <- validate_project_slug(slug) do
      query(
        """
        UPDATE #{@project_table}
        SET enabled = false,
            updated_at = now()
        WHERE slug = $1
        """,
        [slug],
        opts,
        fn
          %{num_rows: 1} -> :ok
          _result -> {:error, :project_not_found}
        end
      )
    end
  end

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts) when is_list(opts) do
    settings = SymphonyElixir.Config.settings!()
    fetch_issues_by_states(settings.tracker.active_states, opts)
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts) when is_list(state_names) and is_list(opts) do
    states = normalize_values(state_names)

    if states == [] do
      {:ok, []}
    else
      query_cards(
        card_query(
          "WHERE c.board_slug = $1 AND c.state = ANY($2)",
          "c.priority ASC NULLS LAST, c.position ASC, c.created_at ASC, c.identifier ASC"
        ),
        [board_slug(opts), states],
        opts
      )
    end
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts) when is_list(issue_ids) and is_list(opts) do
    ids = normalize_values(issue_ids)

    if ids == [] do
      {:ok, []}
    else
      query_cards(
        card_query("WHERE c.board_slug = $1 AND c.id = ANY($2)", "array_position($2, c.id)"),
        [board_slug(opts), ids],
        opts
      )
    end
  end

  @spec create_card(map(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def create_card(attrs, opts) when is_map(attrs) and is_list(opts) do
    title = attrs[:title] || attrs["title"]

    if is_binary(title) and String.trim(title) != "" do
      id = attrs[:id] || attrs["id"] || new_id()
      identifier = attrs[:identifier] || attrs["identifier"] || next_identifier()
      state = attrs[:state] || attrs["state"] || "Backlog"

      query_one(
        """
        INSERT INTO #{@card_table}
          (id, board_slug, identifier, title, description, state, priority, position)
        VALUES
          ($1, $2, $3, $4, $5, $6, $7, next_board_position($2, $6))
        RETURNING id, identifier, title, description, priority, state, branch_name,
                  assignee_id, labels, assigned_to_worker, created_at, updated_at,
                  '[]'::jsonb AS blocked_by
        """,
        [
          id,
          board_slug(opts),
          identifier,
          String.trim(title),
          attrs[:description] || attrs["description"],
          state,
          attrs[:priority] || attrs["priority"]
        ],
        opts
      )
    else
      {:error, :missing_card_title}
    end
  end

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(card_id, body, opts) when is_binary(card_id) and is_binary(body) and is_list(opts) do
    execute(
      """
      INSERT INTO #{@comment_table} (board_slug, card_id, body)
      VALUES ($1, $2, $3)
      """,
      [board_slug(opts), card_id, body],
      opts
    )
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(card_id, state_name, opts)
      when is_binary(card_id) and is_binary(state_name) and is_list(opts) do
    query(
      """
      UPDATE #{@card_table}
      SET state = $3,
          position = next_board_position($1, $3),
          updated_at = now()
      WHERE board_slug = $1 AND id = $2
      """,
      [board_slug(opts), card_id, state_name],
      opts,
      fn
        %{num_rows: 1} -> :ok
        %{num_rows: 0} -> {:error, {:local_board_card_not_found, card_id}}
        _result -> {:error, {:local_board_card_update_failed, card_id}}
      end
    )
  end

  @spec ensure_schema(keyword()) :: :ok | {:error, term()}
  def ensure_schema(opts) when is_list(opts) do
    with_connection(opts, fn conn ->
      ensure_schema_with_connection(conn)
    end)
  end

  @doc false
  @spec connection_options_for_test(String.t()) :: keyword()
  def connection_options_for_test(database_url) when is_binary(database_url) do
    connection_options(database_url)
  end

  defp card_query(where_clause, order_clause) do
    """
    SELECT c.id, c.identifier, c.title, c.description, c.priority, c.state, c.branch_name,
           c.assignee_id, c.labels, c.assigned_to_worker, c.created_at, c.updated_at,
           COALESCE(
             jsonb_agg(
               jsonb_build_object(
                 'id', blocker.id,
                 'identifier', blocker.identifier,
                 'state', blocker.state
               )
             ) FILTER (WHERE blocker.id IS NOT NULL),
             '[]'::jsonb
           ) AS blocked_by
    FROM #{@card_table} c
    LEFT JOIN #{@dependency_table} d
      ON d.card_id = c.id AND d.board_slug = c.board_slug
    LEFT JOIN #{@card_table} blocker
      ON blocker.id = d.blocker_card_id AND blocker.board_slug = c.board_slug
    #{where_clause}
    GROUP BY c.id
    ORDER BY #{order_clause}
    """
  end

  defp query_cards(sql, params, opts) do
    query(sql, params, opts, fn result ->
      {:ok, Enum.map(result.rows, &row_to_issue/1)}
    end)
  end

  defp query_projects(sql, params, opts) do
    query(sql, params, opts, fn result ->
      {:ok, Enum.map(result.rows, &row_to_project/1)}
    end)
  end

  defp query_project(sql, params, opts) do
    query(sql, params, opts, fn
      %{rows: [row]} -> {:ok, row_to_project(row)}
      _result -> {:error, :project_not_found}
    end)
  end

  defp query_one(sql, params, opts) do
    query(sql, params, opts, fn
      %{rows: [row]} -> {:ok, row_to_issue(row)}
      _result -> {:error, :card_not_created}
    end)
  end

  defp execute(sql, params, opts) do
    query(sql, params, opts, fn _result -> :ok end)
  end

  defp query(sql, params, opts, mapper) do
    with :ok <- validate_project_slug(board_slug(opts)) do
      with_connection(opts, fn conn ->
        :ok = ensure_schema_with_connection(conn)
        :ok = ensure_current_project_with_connection(conn, opts)
        mapper.(Postgrex.query!(conn, sql, params))
      end)
    end
  end

  defp with_connection(opts, fun) do
    database_url = Keyword.fetch!(opts, :database_url)

    case Postgrex.start_link(connection_options(database_url)) do
      {:ok, conn} ->
        try do
          fun.(conn)
        rescue
          error -> {:error, error}
        after
          GenServer.stop(conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_schema_with_connection(conn) do
    Enum.each(schema_statements(), fn statement ->
      Postgrex.query!(conn, statement, [])
    end)

    :ok
  end

  defp ensure_current_project_with_connection(conn, opts) do
    case current_project_attrs(opts) do
      {:ok, project} ->
        Postgrex.query!(
          conn,
          "INSERT INTO #{@project_table} (slug, name, directory, repo_url, workspace_root) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (slug) DO NOTHING",
          [project.slug, project.name, project.directory, project.repo_url, project.workspace_root]
        )

        :ok

      :skip ->
        :ok
    end
  end

  defp row_to_issue([
         id,
         identifier,
         title,
         description,
         priority,
         state,
         branch_name,
         assignee_id,
         labels,
         assigned_to_worker,
         created_at,
         updated_at,
         blocked_by
       ]) do
    %Issue{
      id: id,
      identifier: identifier,
      title: title,
      description: description,
      priority: priority,
      state: state,
      branch_name: branch_name,
      url: nil,
      assignee_id: assignee_id,
      labels: labels || [],
      assigned_to_worker: assigned_to_worker,
      created_at: created_at,
      updated_at: updated_at,
      blocked_by: decode_blockers(blocked_by)
    }
  end

  defp row_to_project(row), do: Map.new(Enum.zip(@project_keys, row))

  defp decode_blockers(blockers) when is_list(blockers) do
    Enum.map(blockers, fn
      %{"id" => id, "identifier" => identifier, "state" => state} ->
        %{id: id, identifier: identifier, state: state}

      blocker ->
        blocker
    end)
  end

  defp decode_blockers(_blockers), do: []

  defp connection_options(database_url) when is_binary(database_url) do
    uri = URI.parse(database_url)
    {username, password} = decode_userinfo(uri.userinfo)

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      database: decode_path_database(uri.path),
      username: username || "postgres"
    ]
    |> maybe_put_password(password)
  end

  defp decode_userinfo(nil), do: {nil, nil}

  defp decode_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] -> {URI.decode_www_form(username), URI.decode_www_form(password)}
      [username] -> {URI.decode_www_form(username), nil}
    end
  end

  defp decode_path_database("/" <> database) when database != "" do
    URI.decode_www_form(database)
  end

  defp decode_path_database(_path), do: "postgres"

  defp maybe_put_password(opts, password) when is_binary(password) and password != "" do
    Keyword.put(opts, :password, password)
  end

  defp maybe_put_password(opts, _password), do: opts

  defp normalize_values(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp project_attrs(attrs, opts) do
    slug = optional_string(attrs[:slug] || attrs["slug"])
    name = optional_string(attrs[:name] || attrs["name"]) || slug
    directory = optional_string(attrs[:directory] || attrs["directory"])
    workspace_root = optional_string(attrs[:workspace_root] || attrs["workspace_root"]) || optional_string(Keyword.get(opts, :workspace_root))

    cond do
      is_nil(slug) ->
        {:error, :missing_project_slug}

      not Schema.valid_project_slug?(slug) ->
        {:error, {:invalid_project_slug, slug}}

      is_nil(directory) ->
        {:error, :missing_project_directory}

      is_nil(workspace_root) ->
        {:error, :missing_project_workspace_root}

      true ->
        {:ok,
         %{
           slug: slug,
           name: name,
           directory: directory,
           repo_url: optional_string(attrs[:repo_url] || attrs["repo_url"]),
           workspace_root: workspace_root
         }}
    end
  end

  defp current_project_attrs(opts) do
    slug = optional_string(Keyword.get(opts, :project_slug)) || board_slug(opts)

    project_attrs(
      %{
        slug: slug,
        name: Keyword.get(opts, :project_name),
        directory: Keyword.get(opts, :project_directory),
        repo_url: Keyword.get(opts, :project_repo_url),
        workspace_root: Keyword.get(opts, :workspace_root)
      },
      opts
    )
    |> case do
      {:ok, project} -> {:ok, project}
      {:error, _reason} -> :skip
    end
  end

  defp optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end

  defp optional_string(_value), do: nil

  defp optional_boolean(value) when is_boolean(value), do: value
  defp optional_boolean(_value), do: nil

  defp board_slug(opts) do
    opts
    |> Keyword.get(:board_slug, "default")
    |> to_string()
  end

  defp validate_project_slug(slug) do
    if Schema.valid_project_slug?(slug), do: :ok, else: {:error, {:invalid_project_slug, slug}}
  end

  defp new_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>> ->
      Enum.join([a, b, c, d, e], "-")
    end)
  end

  defp next_identifier do
    "BOARD-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp schema_statements do
    [
      "CREATE TABLE IF NOT EXISTS #{@project_table} (slug text PRIMARY KEY, name text NOT NULL, directory text NOT NULL, repo_url text, workspace_root text NOT NULL, enabled boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now())",
      "CREATE TABLE IF NOT EXISTS #{@card_table} (id text PRIMARY KEY, board_slug text NOT NULL DEFAULT 'default', identifier text NOT NULL, title text NOT NULL, description text, state text NOT NULL DEFAULT 'Backlog', priority integer, position integer NOT NULL DEFAULT 0, branch_name text, assignee_id text, labels text[] NOT NULL DEFAULT ARRAY[]::text[], assigned_to_worker boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE (board_slug, identifier))",
      "CREATE TABLE IF NOT EXISTS #{@comment_table} (id bigserial PRIMARY KEY, board_slug text NOT NULL DEFAULT 'default', card_id text NOT NULL REFERENCES #{@card_table}(id) ON DELETE CASCADE, body text NOT NULL, created_at timestamptz NOT NULL DEFAULT now())",
      "CREATE TABLE IF NOT EXISTS #{@dependency_table} (board_slug text NOT NULL DEFAULT 'default', card_id text NOT NULL REFERENCES #{@card_table}(id) ON DELETE CASCADE, blocker_card_id text NOT NULL REFERENCES #{@card_table}(id) ON DELETE CASCADE, PRIMARY KEY (board_slug, card_id, blocker_card_id))",
      "CREATE INDEX IF NOT EXISTS symphony_board_cards_board_state_position_idx ON #{@card_table} (board_slug, state, position)",
      "CREATE OR REPLACE FUNCTION next_board_position(target_board_slug text, target_state text) RETURNS integer AS $$ SELECT COALESCE(MAX(position), 0) + 1 FROM #{@card_table} WHERE board_slug = target_board_slug AND state = target_state $$ LANGUAGE sql"
    ]
  end
end
