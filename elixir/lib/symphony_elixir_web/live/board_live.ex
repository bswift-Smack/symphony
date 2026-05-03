defmodule SymphonyElixirWeb.BoardLive do
  @moduledoc """
  Drag-and-drop board for the local Symphony tracker.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, LocalBoard}
  alias SymphonyElixir.Config.Schema

  @columns ["Backlog", "Ready", "Running", "Human Review", "Rework", "Merging", "Done", "Cancelled"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       columns: @columns,
       cards: [],
       projects: [],
       project: nil,
       board_slug: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    projects = enabled_projects(load_projects())

    case projects do
      [] ->
        {:noreply,
         assign(socket,
           projects: [],
           project: nil,
           board_slug: nil,
           cards: [],
           error: "Board unavailable: no enabled projects"
         )}

      projects ->
        requested_slug = Map.get(params, "project_slug")

        case selected_project(projects, requested_slug) do
          {:redirect, project} ->
            {:noreply, redirect(socket, to: board_path(project_slug(project)))}

          {:ok, project} ->
            {:noreply, assign_board(socket, project, projects)}
        end
    end
  end

  @impl true
  def handle_event("create_card", %{"card" => card_params}, socket) do
    board_slug = socket.assigns.board_slug

    attrs =
      card_params
      |> Map.take(["title", "description"])
      |> Map.put("state", "Backlog")

    socket =
      case create_card(attrs, board_slug) do
        {:ok, card} ->
          socket
          |> update(:cards, &[card | &1])
          |> assign(:error, nil)

        {:error, reason} ->
          assign(socket, :error, "Card was not created: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event("select_project", %{"board" => %{"project_slug" => project_slug}}, socket) do
    if Schema.valid_project_slug?(project_slug) do
      {:noreply, push_patch(socket, to: board_path(project_slug))}
    else
      {:noreply, assign(socket, :error, "Project was not selected: #{inspect({:invalid_project_slug, project_slug})}")}
    end
  end

  def handle_event("create_project", %{"project" => project_params}, socket) do
    attrs = Map.take(project_params, ["slug", "name", "directory", "repo_url", "workspace_root"])

    with :ok <- validate_project_attrs(attrs),
         {:ok, project} <- create_project(attrs) do
      {:noreply, push_patch(socket, to: board_path(project_slug(project)))}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :error, "Project was not created: #{inspect(reason)}")}
    end
  end

  def handle_event("update_project", %{"project" => project_params}, socket) do
    attrs = Map.take(project_params, ["name", "directory", "repo_url", "workspace_root"])

    case update_project(socket.assigns.board_slug, attrs) do
      {:ok, project} ->
        projects = load_projects()
        {:noreply, assign_board(socket, project, enabled_projects(projects))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Project was not updated: #{inspect(reason)}")}
    end
  end

  def handle_event("disable_project", _params, socket) do
    board_slug = socket.assigns.board_slug

    case disable_project(board_slug) do
      :ok ->
        projects =
          load_projects()
          |> enabled_projects()
          |> Enum.reject(&(project_slug(&1) == board_slug))

        case projects do
          [project | _rest] -> {:noreply, push_patch(socket, to: board_path(project_slug(project)))}
          [] -> {:noreply, redirect(socket, to: "/board")}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Project was not disabled: #{inspect(reason)}")}
    end
  end

  def handle_event("move_card", %{"card_id" => card_id, "state" => state}, socket) do
    socket =
      case move_card(card_id, state, socket.assigns.board_slug) do
        :ok ->
          socket
          |> update(:cards, &move_card_in_memory(&1, card_id, state))
          |> assign(:error, nil)

        {:error, reason} ->
          assign(socket, :error, "Card was not moved: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell board-shell">
      <header class="hero-card board-hero">
        <div class="hero-grid">
          <div class="board-hero-copy">
            <p class="eyebrow">Local control surface</p>
            <h1 class="hero-title">Symphony Board</h1>
            <p class="hero-copy">
              Move cards to Ready to dispatch workers, use Rework for review feedback, and keep Done as the terminal proof column.
            </p>
          </div>

          <aside class="board-hero-panel" aria-label="Selected project">
            <p class="board-panel-kicker">Active project</p>
            <h2><%= project_name(@project) %></h2>
            <dl class="board-meta-list">
              <div>
                <dt>Board</dt>
                <dd>Board: <%= @board_slug %></dd>
              </div>
              <div>
                <dt>Directory</dt>
                <dd>Locked to <%= project_directory(@project) %></dd>
              </div>
            </dl>
            <a class="subtle-button board-nav" href="/">Observability</a>
          </aside>
        </div>
      </header>

      <section class="board-control-panel" aria-label="Project controls">
        <div class="board-control-header">
          <div>
            <p class="eyebrow">Workspace</p>
            <h2 class="section-title">Project controls</h2>
          </div>

          <form id="project-selector-form" phx-change="select_project" class="board-selector-form">
            <label class="board-field board-select-field">
              <span>Project</span>
              <select name="board[project_slug]">
                <option
                  :for={project <- enabled_projects(@projects)}
                  value={project_slug(project)}
                  selected={project_slug(project) == @board_slug}
                >
                  <%= project_name(project) %>
                </option>
              </select>
            </label>
          </form>
        </div>

        <div class="project-editor-grid">
          <form id="edit-project-form" phx-submit="update_project" class="board-form board-form-panel">
            <header class="board-form-header">
              <h3>Selected project</h3>
              <p>Keep the board mapped to the right source directory.</p>
            </header>

            <label class="board-field">
              <span>Project name</span>
              <input name="project[name]" type="text" value={project_name(@project)} required />
            </label>

            <label class="board-field board-field-wide">
              <span>Locked directory</span>
              <input name="project[directory]" type="text" value={project_directory(@project)} required />
            </label>

            <label class="board-field board-field-wide">
              <span>Workspace root</span>
              <input name="project[workspace_root]" type="text" value={project_workspace_root(@project)} required />
            </label>

            <div class="board-actions">
              <button type="submit">Save Project</button>
              <button type="button" class="button-danger" phx-click="disable_project">Disable Project</button>
            </div>
          </form>

          <form id="create-project-form" phx-submit="create_project" class="board-form board-form-panel board-form-panel-muted">
            <header class="board-form-header">
              <h3>New project</h3>
              <p>Add another locked workspace without leaving the board.</p>
            </header>

            <label class="board-field">
              <span>Project slug</span>
              <input name="project[slug]" type="text" required placeholder="project-slug" />
            </label>

            <label class="board-field">
              <span>Project name</span>
              <input name="project[name]" type="text" required placeholder="Project name" />
            </label>

            <label class="board-field board-field-wide">
              <span>Locked directory</span>
              <input name="project[directory]" type="text" required placeholder="/absolute/project/path" />
            </label>

            <label class="board-field board-field-wide">
              <span>Workspace root</span>
              <input name="project[workspace_root]" type="text" required placeholder="/absolute/workspace/root" />
            </label>

            <div class="board-actions">
              <button type="submit" class="secondary">Create Project</button>
            </div>
          </form>
        </div>
      </section>

      <section class="quick-card-panel" aria-label="Create a board card">
        <div class="quick-card-copy">
          <p class="eyebrow">Queue</p>
          <h2 class="section-title">Add a card</h2>
        </div>

        <form id="new-card-form" phx-submit="create_card" class="card-form">
          <label class="board-field">
            <span>Title</span>
            <input name="card[title]" type="text" required placeholder="Small, reviewable task" />
          </label>

          <label class="board-field board-field-wide">
            <span>Description</span>
            <textarea name="card[description]" rows="2" placeholder="Acceptance criteria, proof expected, scope limits"></textarea>
          </label>

          <button type="submit">Add Card</button>
        </form>

        <%= if @error do %>
          <p class="board-error"><%= @error %></p>
        <% end %>
      </section>

      <section class="board-stage" aria-label="Symphony work board">
        <div class="board-stage-header">
          <div>
            <p class="eyebrow">Dispatch lanes</p>
            <h2 class="section-title">Work board</h2>
          </div>
          <span class="board-total numeric"><%= length(@cards) %> cards</span>
        </div>

        <div class="board-grid">
          <article
            :for={column <- @columns}
            id={"board-column-#{column_id(column)}"}
            class="board-column"
            data-state={column}
            phx-hook="BoardColumn"
          >
            <header class="board-column-header">
              <h2><%= column %></h2>
              <span class="board-count numeric"><%= length(cards_for(@cards, column)) %></span>
            </header>

            <div class="board-card-list">
              <%= if cards_for(@cards, column) == [] do %>
                <p class="board-empty">No cards</p>
              <% else %>
                <article
                  :for={card <- cards_for(@cards, column)}
                  id={"board-card-#{card.id}"}
                  class="board-card"
                  data-card-id={card.id}
                  draggable="true"
                  phx-hook="BoardCard"
                >
                  <div class="board-card-topline">
                    <span class="issue-id"><%= card.identifier %></span>
                    <span class={priority_class(card.priority)}><%= priority_label(card.priority) %></span>
                  </div>
                  <h3><%= card.title %></h3>
                  <%= if card.description do %>
                    <p><%= card.description %></p>
                  <% end %>
                </article>
              <% end %>
            </div>
          </article>
        </div>
      </section>
    </section>
    """
  end

  defp assign_board(socket, project, projects) do
    board_slug = project_slug(project)

    case list_cards(board_slug) do
      {:ok, cards} ->
        socket
        |> assign(:columns, @columns)
        |> assign(:cards, cards)
        |> assign(:projects, projects)
        |> assign(:project, project)
        |> assign(:board_slug, board_slug)
        |> assign(:error, nil)

      {:error, reason} ->
        socket
        |> assign(:columns, @columns)
        |> assign(:cards, [])
        |> assign(:projects, projects)
        |> assign(:project, project)
        |> assign(:board_slug, board_slug)
        |> assign(:error, "Board unavailable: #{inspect(reason)}")
    end
  end

  defp selected_project(projects, requested_slug) when requested_slug in [nil, ""] do
    {:redirect, hd(projects)}
  end

  defp selected_project(projects, requested_slug) do
    case Enum.find(projects, &(project_slug(&1) == requested_slug)) do
      nil -> {:redirect, hd(projects)}
      project -> {:ok, project}
    end
  end

  defp load_projects do
    api = board_api_module()

    try do
      case apply_project_call(api, :list_projects, []) do
        {:ok, projects} -> projects
        {:error, _reason} -> [settings_project()]
      end
    rescue
      UndefinedFunctionError -> [settings_project()]
    end
  end

  defp list_cards(board_slug) do
    api = board_api_module()

    cond do
      api == LocalBoard -> LocalBoard.store_module().list_cards(board_store_opts(board_slug))
      function_exported?(api, :list_cards, 1) -> api.list_cards(board_slug)
      true -> LocalBoard.list_cards()
    end
  end

  defp create_card(attrs, board_slug) do
    api = board_api_module()

    cond do
      api == LocalBoard -> LocalBoard.store_module().create_card(attrs, board_store_opts(board_slug))
      function_exported?(api, :create_card, 2) -> api.create_card(attrs, board_slug)
      true -> LocalBoard.create_card(attrs)
    end
  end

  defp create_project(attrs) do
    api = board_api_module()

    if function_exported?(api, :create_project, 1) do
      api.create_project(attrs)
    else
      {:error, :project_management_unavailable}
    end
  end

  defp update_project(board_slug, attrs) do
    api = board_api_module()

    if function_exported?(api, :update_project, 2) do
      api.update_project(board_slug, attrs)
    else
      {:error, :project_management_unavailable}
    end
  end

  defp disable_project(board_slug) do
    api = board_api_module()

    if function_exported?(api, :disable_project, 1) do
      api.disable_project(board_slug)
    else
      {:error, :project_management_unavailable}
    end
  end

  defp move_card(card_id, state, board_slug) do
    api = board_api_module()

    cond do
      api == LocalBoard -> LocalBoard.move_card(card_id, state, board_store_opts(board_slug))
      function_exported?(api, :move_card, 3) -> api.move_card(card_id, state, board_slug)
      true -> LocalBoard.move_card(card_id, state)
    end
  end

  defp board_store_opts(board_slug) do
    LocalBoard.store_opts()
    |> Keyword.put(:board_slug, board_slug)
  end

  defp apply_project_call(api, function_name, args) do
    if function_exported?(api, function_name, length(args)) do
      apply(api, function_name, args)
    else
      {:ok, [settings_project()]}
    end
  end

  defp board_api_module do
    Application.get_env(:symphony_elixir, :local_board_api_module, LocalBoard)
  end

  defp settings_project do
    settings = Config.settings!()

    %{
      slug: settings.project.slug || settings.tracker.board_slug || "default",
      name: settings.project.name || settings.project.slug || settings.tracker.board_slug || "Project",
      directory: settings.project.directory || "",
      repo_url: settings.project.repo_url,
      workspace_root: settings.project.workspace_root || settings.workspace.root,
      enabled: true
    }
  end

  defp enabled_projects(projects) do
    Enum.filter(projects, &(project_enabled?(&1) and Schema.valid_project_slug?(project_slug(&1))))
  end

  defp project_enabled?(project) do
    Map.get(project, :enabled, Map.get(project, :enabled?, Map.get(project, "enabled", Map.get(project, "enabled?", true)))) != false
  end

  defp board_path(slug), do: "/board/#{slug}"

  defp validate_project_attrs(%{"slug" => slug}) do
    if Schema.valid_project_slug?(slug), do: :ok, else: {:error, {:invalid_project_slug, slug}}
  end

  defp validate_project_attrs(_attrs), do: {:error, :missing_project_slug}

  defp move_card_in_memory(cards, card_id, state) do
    Enum.map(cards, fn
      %{id: ^card_id} = card -> %{card | state: state}
      card -> card
    end)
  end

  defp cards_for(cards, column) do
    Enum.filter(cards, &(&1.state == column))
  end

  defp column_id(column) do
    column
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp priority_label(priority) when is_integer(priority), do: "P#{priority}"
  defp priority_label(_priority), do: "P-"

  defp priority_class(priority) when is_integer(priority) and priority in 1..2,
    do: "board-priority board-priority-hot"

  defp priority_class(_priority), do: "board-priority"

  defp project_slug(%{slug: slug}) when is_binary(slug), do: slug
  defp project_slug(%{"slug" => slug}) when is_binary(slug), do: slug
  defp project_slug(_project), do: "default"

  defp project_directory(%{directory: directory}) when is_binary(directory), do: directory
  defp project_directory(%{"directory" => directory}) when is_binary(directory), do: directory
  defp project_directory(_project), do: ""

  defp project_workspace_root(%{workspace_root: workspace_root}) when is_binary(workspace_root), do: workspace_root
  defp project_workspace_root(%{"workspace_root" => workspace_root}) when is_binary(workspace_root), do: workspace_root
  defp project_workspace_root(_project), do: ""

  defp project_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp project_name(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp project_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp project_name(%{"slug" => slug}) when is_binary(slug) and slug != "", do: slug
  defp project_name(_project), do: "Project"
end
