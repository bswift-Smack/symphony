defmodule SymphonyElixir.LocalBoard do
  @moduledoc """
  Local board facade for dashboard actions and tracker reads.
  """

  alias SymphonyElixir.Linear.Issue

  @type project :: %{
          slug: String.t(),
          name: String.t(),
          directory: String.t(),
          repo_url: String.t() | nil,
          workspace_root: String.t(),
          enabled: boolean(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type card_attrs :: %{
          optional(:title) => String.t(),
          optional(:description) => String.t() | nil,
          optional(:state) => String.t(),
          optional(:priority) => integer() | nil
        }

  @spec list_cards() :: {:ok, [Issue.t()]} | {:error, term()}
  def list_cards do
    store_module().list_cards(store_opts())
  end

  @spec list_projects() :: {:ok, [project()]} | {:error, term()}
  def list_projects do
    store_module().list_projects(store_opts())
  end

  @spec get_project(String.t()) :: {:ok, project()} | {:error, term()}
  def get_project(slug) when is_binary(slug) do
    store_module().get_project(slug, store_opts())
  end

  @spec create_project(map()) :: {:ok, project()} | {:error, term()}
  def create_project(attrs) when is_map(attrs) do
    store_module().create_project(attrs, store_opts())
  end

  @spec update_project(String.t(), map()) :: {:ok, project()} | {:error, term()}
  def update_project(slug, attrs) when is_binary(slug) and is_map(attrs) do
    store_module().update_project(slug, attrs, store_opts())
  end

  @spec disable_project(String.t()) :: :ok | {:error, term()}
  def disable_project(slug) when is_binary(slug) do
    store_module().disable_project(slug, store_opts())
  end

  @spec cards_by_state([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def cards_by_state(states) when is_list(states) do
    fetch_across_enabled_projects(fn project ->
      store_module().fetch_issues_by_states(states, store_opts(project))
    end)
  end

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    settings = SymphonyElixir.Config.settings!()
    cards_by_state(settings.tracker.active_states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_across_enabled_projects(fn project ->
      store_module().fetch_issue_states_by_ids(issue_ids, store_opts(project))
    end)
  end

  @spec create_card(card_attrs()) :: {:ok, Issue.t()} | {:error, term()}
  def create_card(attrs) when is_map(attrs) do
    store_module().create_card(attrs, store_opts())
  end

  @spec move_card(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def move_card(card_id, state_name, context \\ nil) when is_binary(card_id) and is_binary(state_name) do
    with {:ok, project} <- card_project(card_id, context) do
      store_module().update_issue_state(card_id, state_name, store_opts(project))
    end
  end

  @spec add_comment(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def add_comment(card_id, body, context \\ nil) when is_binary(card_id) and is_binary(body) do
    with {:ok, project} <- card_project(card_id, context) do
      store_module().create_comment(card_id, body, store_opts(project))
    end
  end

  @spec resolve_card_context(String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_card_context(card_id) when is_binary(card_id) do
    with {:ok, project} <- find_card_project(card_id) do
      {:ok, %{board_slug: project_slug(project), project: project}}
    end
  end

  @spec store_module() :: module()
  def store_module do
    Application.get_env(:symphony_elixir, :local_board_store_module, SymphonyElixir.LocalBoard.Store)
  end

  @spec store_opts() :: keyword()
  def store_opts do
    settings = SymphonyElixir.Config.settings!()

    [
      database_url: settings.tracker.database_url,
      board_slug: settings.tracker.board_slug || "default",
      project_slug: settings.project.slug,
      project_name: settings.project.name,
      project_directory: settings.project.directory,
      project_repo_url: settings.project.repo_url,
      workspace_root: settings.project.workspace_root || settings.workspace.root
    ]
  end

  @spec store_opts(map()) :: keyword()
  def store_opts(project) when is_map(project) do
    settings = SymphonyElixir.Config.settings!()
    slug = project_slug(project)

    [
      database_url: settings.tracker.database_url,
      board_slug: slug,
      project_slug: slug,
      project_name: project_name(project),
      project_directory: project_directory(project),
      project_repo_url: project_repo_url(project),
      workspace_root: project_workspace_root(project) || settings.workspace.root,
      project: project
    ]
  end

  defp fetch_across_enabled_projects(fetcher) when is_function(fetcher, 1) do
    with {:ok, projects} <- enabled_projects() do
      Enum.reduce_while(projects, {:ok, []}, fn project, {:ok, issues_acc} ->
        case fetcher.(project) do
          {:ok, issues} -> {:cont, {:ok, issues_acc ++ attach_project(issues, project)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp enabled_projects do
    if function_exported?(store_module(), :list_projects, 1) do
      case list_projects() do
        {:ok, projects} ->
          {:ok, Enum.filter(projects, &project_enabled?/1)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, [settings_project()]}
    end
  end

  defp attach_project(issues, project) when is_list(issues) do
    if Map.get(project, :__fallback_project__) do
      issues
    else
      Enum.map(issues, fn
        %Issue{} = issue -> %{issue | project: project}
        issue when is_map(issue) -> Map.put(issue, :project, project)
        issue -> issue
      end)
    end
  end

  defp card_project(_card_id, project) when is_map(project), do: {:ok, project}

  defp card_project(card_id, opts) when is_list(opts) do
    case Keyword.get(opts, :project) || string_key_value(opts, "project") do
      project when is_map(project) -> {:ok, project}
      _ -> find_card_project(card_id)
    end
  end

  defp card_project(card_id, _context), do: find_card_project(card_id)

  defp string_key_value(values, key) when is_list(values) do
    Enum.find_value(values, fn
      {^key, value} -> value
      _value -> nil
    end)
  end

  defp find_card_project(card_id) do
    with {:ok, projects} <- enabled_projects() do
      Enum.reduce_while(projects, {:error, {:local_board_card_not_found, card_id}}, fn project, _acc ->
        case store_module().fetch_issue_states_by_ids([card_id], store_opts(project)) do
          {:ok, [_issue | _]} -> {:halt, {:ok, project}}
          {:ok, []} -> {:cont, {:error, {:local_board_card_not_found, card_id}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp project_enabled?(%{enabled: false}), do: false
  defp project_enabled?(%{enabled?: false}), do: false
  defp project_enabled?(%{"enabled" => false}), do: false
  defp project_enabled?(%{"enabled?" => false}), do: false
  defp project_enabled?(_project), do: true

  defp settings_project do
    settings = SymphonyElixir.Config.settings!()

    %{
      slug: settings.project.slug || settings.tracker.board_slug || "default",
      name: settings.project.name,
      directory: settings.project.directory,
      repo_url: settings.project.repo_url,
      workspace_root: settings.project.workspace_root || settings.workspace.root,
      enabled: true,
      __fallback_project__: true
    }
  end

  defp project_slug(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp project_slug(%{"slug" => slug}) when is_binary(slug) and slug != "", do: slug
  defp project_slug(_project), do: "default"

  defp project_name(%{name: name}) when is_binary(name), do: name
  defp project_name(%{"name" => name}) when is_binary(name), do: name
  defp project_name(_project), do: nil

  defp project_directory(%{directory: directory}) when is_binary(directory), do: directory
  defp project_directory(%{"directory" => directory}) when is_binary(directory), do: directory
  defp project_directory(_project), do: nil

  defp project_repo_url(%{repo_url: repo_url}) when is_binary(repo_url), do: repo_url
  defp project_repo_url(%{"repo_url" => repo_url}) when is_binary(repo_url), do: repo_url
  defp project_repo_url(_project), do: nil

  defp project_workspace_root(%{workspace_root: workspace_root}) when is_binary(workspace_root), do: workspace_root
  defp project_workspace_root(%{"workspace_root" => workspace_root}) when is_binary(workspace_root), do: workspace_root
  defp project_workspace_root(_project), do: nil
end
