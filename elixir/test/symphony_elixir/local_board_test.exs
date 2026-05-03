defmodule SymphonyElixir.LocalBoardTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.LocalBoard
  alias SymphonyElixir.Tracker.LocalBoard, as: LocalBoardTracker

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeStore do
    @spec list_cards(keyword()) :: {:ok, [SymphonyElixir.Linear.Issue.t()]}
    def list_cards(_opts) do
      {:ok, Application.get_env(:symphony_elixir, :local_board_test_cards, [])}
    end

    @spec create_card(map(), keyword()) :: {:ok, SymphonyElixir.Linear.Issue.t()}
    def create_card(attrs, _opts) do
      issue = %SymphonyElixir.Linear.Issue{
        id: "card-new",
        identifier: "BOARD-2",
        title: attrs["title"] || attrs[:title],
        description: attrs["description"] || attrs[:description],
        state: attrs["state"] || attrs[:state] || "Backlog"
      }

      send_event({:create_card, attrs})
      {:ok, issue}
    end

    @spec fetch_candidate_issues(keyword()) :: {:ok, [SymphonyElixir.Linear.Issue.t()]}
    def fetch_candidate_issues(_opts) do
      {:ok, Application.get_env(:symphony_elixir, :local_board_test_candidate_issues, [])}
    end

    @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [SymphonyElixir.Linear.Issue.t()]}
    def fetch_issues_by_states(states, _opts) do
      send_event({:fetch_issues_by_states, states})
      {:ok, Application.get_env(:symphony_elixir, :local_board_test_issues_by_states, [])}
    end

    @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [SymphonyElixir.Linear.Issue.t()]}
    def fetch_issue_states_by_ids(issue_ids, _opts) do
      send_event({:fetch_issue_states_by_ids, issue_ids})
      {:ok, Application.get_env(:symphony_elixir, :local_board_test_issues_by_ids, [])}
    end

    @spec create_comment(String.t(), String.t(), keyword()) :: :ok
    def create_comment(issue_id, body, _opts) do
      send_event({:create_comment, issue_id, body})
      :ok
    end

    @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok
    def update_issue_state(issue_id, state_name, _opts) do
      send_event({:update_issue_state, issue_id, state_name})
      :ok
    end

    defp send_event(message) do
      case Application.get_env(:symphony_elixir, :local_board_test_recipient) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  defmodule FakeBoardApi do
    def list_projects do
      {:ok,
       Application.get_env(:symphony_elixir, :local_board_test_projects, [
         %{slug: "pilot", name: "Pilot Project", directory: "/tmp/pilot", enabled?: true}
       ])}
    end

    def list_cards(board_slug) do
      send_event({:list_cards, board_slug})

      cards =
        :symphony_elixir
        |> Application.get_env(:local_board_test_cards_by_board, %{})
        |> Map.get(board_slug, [])

      {:ok, cards}
    end

    def create_card(attrs, board_slug) do
      issue = %SymphonyElixir.Linear.Issue{
        id: "card-new-#{board_slug}",
        identifier: "BOARD-NEW",
        title: attrs["title"] || attrs[:title],
        description: attrs["description"] || attrs[:description],
        state: attrs["state"] || attrs[:state] || "Backlog"
      }

      send_event({:create_card, board_slug, attrs})
      {:ok, issue}
    end

    def create_project(attrs) do
      send_event({:create_project, attrs})

      {:ok,
       %{
         slug: attrs["slug"],
         name: attrs["name"],
         directory: attrs["directory"],
         workspace_root: attrs["workspace_root"],
         enabled?: true
       }}
    end

    def update_project(slug, attrs) do
      send_event({:update_project, slug, attrs})

      {:ok,
       %{
         slug: slug,
         name: attrs["name"],
         directory: attrs["directory"],
         workspace_root: attrs["workspace_root"],
         enabled?: true
       }}
    end

    def disable_project(slug) do
      send_event({:disable_project, slug})
      :ok
    end

    defp send_event(message) do
      case Application.get_env(:symphony_elixir, :local_board_test_recipient) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  setup do
    previous_store = Application.get_env(:symphony_elixir, :local_board_store_module)
    previous_api = Application.get_env(:symphony_elixir, :local_board_api_module)

    Application.put_env(:symphony_elixir, :local_board_store_module, FakeStore)
    Application.put_env(:symphony_elixir, :local_board_test_recipient, self())

    on_exit(fn ->
      if is_nil(previous_store) do
        Application.delete_env(:symphony_elixir, :local_board_store_module)
      else
        Application.put_env(:symphony_elixir, :local_board_store_module, previous_store)
      end

      if is_nil(previous_api) do
        Application.delete_env(:symphony_elixir, :local_board_api_module)
      else
        Application.put_env(:symphony_elixir, :local_board_api_module, previous_api)
      end

      Application.delete_env(:symphony_elixir, :local_board_test_cards)
      Application.delete_env(:symphony_elixir, :local_board_test_cards_by_board)
      Application.delete_env(:symphony_elixir, :local_board_test_projects)
      Application.delete_env(:symphony_elixir, :local_board_test_candidate_issues)
      Application.delete_env(:symphony_elixir, :local_board_test_issues_by_states)
      Application.delete_env(:symphony_elixir, :local_board_test_issues_by_ids)
      Application.delete_env(:symphony_elixir, :local_board_test_recipient)
    end)

    :ok
  end

  test "local board tracker is selected and delegates through the configured store" do
    issue = %Issue{
      id: "card-1",
      identifier: "BOARD-1",
      title: "Make local boards work",
      state: "Ready",
      priority: 2
    }

    Application.put_env(:symphony_elixir, :local_board_test_candidate_issues, [issue])
    Application.put_env(:symphony_elixir, :local_board_test_issues_by_states, [issue])
    Application.put_env(:symphony_elixir, :local_board_test_issues_by_ids, [issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot",
      tracker_active_states: ["Ready", "Rework"],
      tracker_terminal_states: ["Done", "Cancelled"]
    )

    assert Config.settings!().tracker.kind == "local_board"
    assert SymphonyElixir.Tracker.adapter() == LocalBoardTracker
    assert :ok = Config.validate!()

    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states(["Ready"])
    assert_receive {:fetch_issues_by_states, ["Ready"]}

    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["card-1"])
    assert_receive {:fetch_issue_states_by_ids, ["card-1"]}

    assert :ok = SymphonyElixir.Tracker.create_comment("card-1", "plan posted")
    assert_receive {:create_comment, "card-1", "plan posted"}

    assert :ok = SymphonyElixir.Tracker.update_issue_state("card-1", "Human Review")
    assert_receive {:update_issue_state, "card-1", "Human Review"}
  end

  test "local board requires a database url" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: nil,
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_directory: "/tmp/pilot"
    )

    assert {:error, :missing_local_board_database_url} = Config.validate!()
  end

  test "local board requires and exposes a project-locked board context" do
    project_directory = Path.expand("/tmp/symphony-project-lock")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "smackchat",
      project_slug: "smackchat",
      project_name: "SmackChat",
      project_directory: project_directory,
      prompt: "Project {{ project.slug }} is locked to {{ project.directory }} for {{ issue.identifier }}."
    )

    assert :ok = Config.validate!()
    assert Config.settings!().project.slug == "smackchat"
    assert Config.settings!().project.name == "SmackChat"
    assert Config.settings!().project.directory == project_directory

    prompt =
      PromptBuilder.build_prompt(%Issue{
        id: "card-1",
        identifier: "BOARD-1",
        title: "Use the locked project",
        state: "Ready"
      })

    assert prompt =~ "Project smackchat is locked to #{project_directory}"
    assert prompt =~ "BOARD-1"
  end

  test "local board rejects mismatched board and project slugs" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "symphony",
      project_slug: "smackchat",
      project_directory: "/tmp/smackchat"
    )

    assert {:error, {:local_board_project_slug_mismatch, "symphony", "smackchat"}} = Config.validate!()
  end

  test "local board rejects unsafe project slugs before they become board identifiers" do
    for unsafe_slug <- ["bad slug", "bad/slug", "bad?slug", "bad&slug", "bad=slug"] do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "local_board",
        tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
        tracker_board_slug: unsafe_slug,
        project_slug: unsafe_slug,
        project_directory: "/tmp/pilot"
      )

      assert {:error, {:invalid_local_board_project_slug, ^unsafe_slug}} = Config.validate!()
    end
  end

  test "local board helpers create cards, move cards, and add comments through the store" do
    issue = %Issue{
      id: "card-1",
      identifier: "BOARD-1",
      title: "Existing local board card",
      state: "Backlog"
    }

    Application.put_env(:symphony_elixir, :local_board_test_issues_by_states, [])
    Application.put_env(:symphony_elixir, :local_board_test_issues_by_ids, [issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot"
    )

    assert {:ok, []} = LocalBoard.cards_by_state(["Backlog"])
    assert_receive {:fetch_issues_by_states, ["Backlog"]}

    assert :ok = LocalBoard.move_card("card-1", "Ready")
    assert_receive {:update_issue_state, "card-1", "Ready"}

    assert :ok = LocalBoard.add_comment("card-1", "Reviewed")
    assert_receive {:create_comment, "card-1", "Reviewed"}
  end

  test "local board move and comment return errors when the card does not exist" do
    Application.put_env(:symphony_elixir, :local_board_test_issues_by_ids, [])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot"
    )

    assert {:error, {:local_board_card_not_found, "missing-card"}} =
             LocalBoard.move_card("missing-card", "Ready")

    assert_receive {:fetch_issue_states_by_ids, ["missing-card"]}
    refute_received {:update_issue_state, "missing-card", "Ready"}

    assert {:error, {:local_board_card_not_found, "missing-card"}} =
             LocalBoard.add_comment("missing-card", "Reviewed")

    assert_receive {:fetch_issue_states_by_ids, ["missing-card"]}
    refute_received {:create_comment, "missing-card", "Reviewed"}
  end

  test "local board renders cards, creates cards, and moves cards between columns" do
    import Phoenix.ConnTest
    import Phoenix.LiveViewTest

    issue = %Issue{
      id: "card-1",
      identifier: "BOARD-1",
      title: "Replace Linear with a local board",
      description: "Use Postgres-backed cards",
      state: "Backlog",
      priority: 1
    }

    Application.put_env(:symphony_elixir, :local_board_test_cards, [issue])
    Application.put_env(:symphony_elixir, :local_board_test_issues_by_ids, [issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot"
    )

    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/board/pilot")

    assert html =~ "Pilot Project"
    assert html =~ "Board: pilot"
    assert html =~ "Locked to /tmp/pilot"
    assert html =~ "Replace Linear with a local board"
    assert html =~ "Human Review"
    refute html =~ "card[project_slug]"

    view
    |> form("#new-card-form", card: %{title: "Write workflow prompt", description: "Make validation explicit"})
    |> render_submit()

    assert_receive {:create_card,
                    %{
                      "description" => "Make validation explicit",
                      "state" => "Backlog",
                      "title" => "Write workflow prompt"
                    }}

    assert render_hook(view, :move_card, %{"card_id" => "card-1", "state" => "Ready"}) =~
             "Replace Linear with a local board"

    assert_receive {:update_issue_state, "card-1", "Ready"}
  end

  test "board refuses stale card moves without moving the card in the UI" do
    import Phoenix.ConnTest
    import Phoenix.LiveViewTest

    issue = %Issue{
      id: "stale-card",
      identifier: "BOARD-STALE",
      title: "Deleted behind the dashboard",
      description: "The LiveView still has a stale copy",
      state: "Backlog",
      priority: 1
    }

    Application.put_env(:symphony_elixir, :local_board_test_cards, [issue])
    Application.put_env(:symphony_elixir, :local_board_test_issues_by_ids, [])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot"
    )

    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/board/pilot")

    assert has_element?(view, "#board-column-backlog #board-card-stale-card")
    refute has_element?(view, "#board-column-ready #board-card-stale-card")

    result = render_hook(view, :move_card, %{"card_id" => "stale-card", "state" => "Ready"})

    assert result =~ "Card was not moved"
    assert result =~ "local_board_card_not_found"
    assert_receive {:fetch_issue_states_by_ids, ["stale-card"]}
    refute_received {:update_issue_state, "stale-card", "Ready"}
    assert has_element?(view, "#board-column-backlog #board-card-stale-card")
    refute has_element?(view, "#board-column-ready #board-card-stale-card")
  end

  test "board root redirects to the first enabled project" do
    Application.put_env(:symphony_elixir, :local_board_api_module, FakeBoardApi)

    Application.put_env(:symphony_elixir, :local_board_test_projects, [
      %{slug: "disabled", name: "Disabled Project", directory: "/tmp/disabled", enabled?: false},
      %{slug: "pilot", name: "Pilot Project", directory: "/tmp/pilot", enabled?: true}
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot"
    )

    start_test_endpoint()

    assert {:error, {:redirect, %{to: "/board/pilot"}}} = live(build_conn(), "/board")
  end

  test "board root skips unsafe project slugs before redirecting" do
    Application.put_env(:symphony_elixir, :local_board_api_module, FakeBoardApi)

    Application.put_env(:symphony_elixir, :local_board_test_projects, [
      %{slug: "bad/slug", name: "Unsafe Project", directory: "/tmp/unsafe", enabled?: true},
      %{slug: "pilot", name: "Pilot Project", directory: "/tmp/pilot", enabled?: true}
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot"
    )

    start_test_endpoint()

    assert {:error, {:redirect, %{to: "/board/pilot"}}} = live(build_conn(), "/board")
  end

  test "board create project rejects unsafe slugs before routing or API calls" do
    Application.put_env(:symphony_elixir, :local_board_api_module, FakeBoardApi)

    Application.put_env(:symphony_elixir, :local_board_test_projects, [
      %{slug: "pilot", name: "Pilot Project", directory: "/tmp/pilot", enabled?: true}
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot"
    )

    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/board/pilot")

    result =
      view
      |> form("#create-project-form",
        project: %{slug: "bad slug", name: "Bad Project", directory: "/tmp/bad"}
      )
      |> render_submit()

    assert result =~ "Project was not created"
    assert result =~ "invalid_project_slug"
    refute_receive {:create_project, _attrs}
  end

  test "postgres store rejects unsafe slugs before opening a database connection" do
    opts = [database_url: "postgres://postgres@127.0.0.1:1/unreachable", board_slug: "bad/slug"]

    assert {:error, {:invalid_project_slug, "bad/slug"}} = SymphonyElixir.LocalBoard.Store.list_cards(opts)

    assert {:error, {:invalid_project_slug, "bad slug"}} =
             SymphonyElixir.LocalBoard.Store.create_project(
               %{slug: "bad slug", directory: "/tmp/bad", workspace_root: "/tmp/workspaces"},
               Keyword.put(opts, :board_slug, "pilot")
             )
  end

  test "board renders a project selector and switches the selected project" do
    Application.put_env(:symphony_elixir, :local_board_api_module, FakeBoardApi)

    Application.put_env(:symphony_elixir, :local_board_test_projects, [
      %{slug: "pilot", name: "Pilot Project", directory: "/tmp/pilot", enabled?: true},
      %{slug: "archive", name: "Archive Project", directory: "/tmp/archive", enabled?: true}
    ])

    Application.put_env(:symphony_elixir, :local_board_test_cards_by_board, %{
      "pilot" => [],
      "archive" => []
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot"
    )

    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/board/pilot")

    assert html =~ ~s(id="project-selector-form")
    assert html =~ "Pilot Project"
    assert html =~ "Archive Project"
    assert html =~ "Board: pilot"
    assert html =~ "Locked to /tmp/pilot"

    view
    |> form("#project-selector-form", board: %{project_slug: "archive"})
    |> render_change()

    assert_patch(view, "/board/archive")

    archive_html = render(view)

    assert archive_html =~ "Archive Project"
    assert archive_html =~ "Board: archive"
    assert archive_html =~ "Locked to /tmp/archive"
  end

  test "board only renders cards for the selected project" do
    Application.put_env(:symphony_elixir, :local_board_api_module, FakeBoardApi)

    Application.put_env(:symphony_elixir, :local_board_test_projects, [
      %{slug: "pilot", name: "Pilot Project", directory: "/tmp/pilot", enabled?: true},
      %{slug: "archive", name: "Archive Project", directory: "/tmp/archive", enabled?: true}
    ])

    Application.put_env(:symphony_elixir, :local_board_test_cards_by_board, %{
      "pilot" => [
        %Issue{id: "pilot-card", identifier: "PILOT-1", title: "Pilot only card", state: "Backlog"}
      ],
      "archive" => [
        %Issue{id: "archive-card", identifier: "ARCH-1", title: "Archive only card", state: "Backlog"}
      ]
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot"
    )

    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/board/archive")

    assert html =~ "Archive only card"
    refute html =~ "Pilot only card"
    assert_receive {:list_cards, "archive"}
  end

  test "creating a board card sends the selected project board slug" do
    Application.put_env(:symphony_elixir, :local_board_api_module, FakeBoardApi)

    Application.put_env(:symphony_elixir, :local_board_test_projects, [
      %{slug: "pilot", name: "Pilot Project", directory: "/tmp/pilot", enabled?: true},
      %{slug: "archive", name: "Archive Project", directory: "/tmp/archive", enabled?: true}
    ])

    Application.put_env(:symphony_elixir, :local_board_test_cards_by_board, %{
      "pilot" => [],
      "archive" => []
    })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot"
    )

    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/board/archive")

    view
    |> form("#new-card-form", card: %{title: "Archive task", description: "Store on the archive board"})
    |> render_submit()

    assert_receive {:create_card, "archive",
                    %{
                      "description" => "Store on the archive board",
                      "state" => "Backlog",
                      "title" => "Archive task"
                    }}
  end

  test "board create and edit project forms expose and persist workspace root" do
    Application.put_env(:symphony_elixir, :local_board_api_module, FakeBoardApi)

    Application.put_env(:symphony_elixir, :local_board_test_projects, [
      %{
        slug: "pilot",
        name: "Pilot Project",
        directory: "/tmp/pilot",
        workspace_root: "/tmp/pilot-workspaces",
        enabled?: true
      }
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot",
      workspace_root: "/tmp/pilot-workspaces"
    )

    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/board/pilot")

    assert html =~ ~s(name="project[workspace_root]")
    assert html =~ ~s(value="/tmp/pilot-workspaces")

    view
    |> form("#edit-project-form",
      project: %{
        name: "Pilot Edited",
        directory: "/tmp/pilot-edited",
        workspace_root: "/tmp/pilot-workspaces-edited"
      }
    )
    |> render_submit()

    assert_receive {:update_project, "pilot",
                    %{
                      "name" => "Pilot Edited",
                      "directory" => "/tmp/pilot-edited",
                      "workspace_root" => "/tmp/pilot-workspaces-edited"
                    }}

    view
    |> form("#create-project-form",
      project: %{
        slug: "created",
        name: "Created Project",
        directory: "/tmp/created",
        workspace_root: "/tmp/created-workspaces"
      }
    )
    |> render_submit()

    assert_receive {:create_project,
                    %{
                      "slug" => "created",
                      "name" => "Created Project",
                      "directory" => "/tmp/created",
                      "workspace_root" => "/tmp/created-workspaces"
                    }}
  end

  test "board renders project controls and card creation as distinct modern panels" do
    Application.put_env(:symphony_elixir, :local_board_api_module, FakeBoardApi)

    Application.put_env(:symphony_elixir, :local_board_test_projects, [
      %{
        slug: "pilot",
        name: "Pilot Project",
        directory: "/tmp/pilot",
        workspace_root: "/tmp/pilot-workspaces",
        enabled?: true
      }
    ])

    Application.put_env(:symphony_elixir, :local_board_test_cards_by_board, %{"pilot" => []})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: "postgres://postgres:postgres@localhost:5431/symphony_board_test",
      tracker_board_slug: "pilot",
      project_slug: "pilot",
      project_name: "Pilot Project",
      project_directory: "/tmp/pilot",
      workspace_root: "/tmp/pilot-workspaces"
    )

    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/board/pilot")

    assert has_element?(view, ".board-control-panel #project-selector-form")
    assert has_element?(view, ".project-editor-grid #edit-project-form")
    assert has_element?(view, ".project-editor-grid #create-project-form")
    assert has_element?(view, ".quick-card-panel #new-card-form")
    assert has_element?(view, ".board-stage .board-grid")
    refute html =~ ~s(class="section-card board-compose")
  end

  if System.get_env("SYMPHONY_BOARD_DATABASE_URL") do
    test "postgres store persists cards, state moves, comments, and candidate reads" do
      database_url = System.fetch_env!("SYMPHONY_BOARD_DATABASE_URL")
      board_slug = "test-#{System.unique_integer([:positive])}"

      Application.delete_env(:symphony_elixir, :local_board_store_module)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "local_board",
        tracker_database_url: database_url,
        tracker_board_slug: board_slug,
        project_slug: board_slug,
        project_name: "Postgres Test Project",
        project_directory: "/tmp/#{board_slug}",
        tracker_active_states: ["Ready"],
        tracker_terminal_states: ["Done", "Cancelled"]
      )

      store_opts = LocalBoard.store_opts()

      try do
        assert :ok = SymphonyElixir.LocalBoard.Store.ensure_schema(store_opts)

        assert {:ok, card} =
                 LocalBoard.create_card(%{
                   title: "Persist local board cards",
                   description: "Prove Postgres-backed board operations",
                   state: "Backlog",
                   priority: 1
                 })

        assert card.title == "Persist local board cards"
        assert card.state == "Backlog"

        assert :ok = LocalBoard.move_card(card.id, "Ready")

        assert {:ok, [ready_card]} = SymphonyElixir.Tracker.fetch_candidate_issues()
        assert ready_card.id == card.id
        assert ready_card.state == "Ready"

        assert :ok = LocalBoard.add_comment(card.id, "Plan posted before implementation")
        assert comment_count(database_url, board_slug, card.id) == 1
      after
        cleanup_board(database_url, board_slug)
        Application.put_env(:symphony_elixir, :local_board_store_module, FakeStore)
      end
    end
  end

  test "postgres store seeds the workflow project and supports create edit disable list and get APIs" do
    database_url = local_board_database_url()
    seed_slug = "seed-#{System.unique_integer([:positive])}"
    created_slug = "created-#{System.unique_integer([:positive])}"
    seed_directory = "/tmp/#{seed_slug}"
    created_directory = "/tmp/#{created_slug}"
    workspace_root = "/tmp/#{seed_slug}-workspace"

    Application.delete_env(:symphony_elixir, :local_board_store_module)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: database_url,
      tracker_board_slug: seed_slug,
      project_slug: seed_slug,
      project_name: "Seed Project",
      project_directory: seed_directory,
      project_repo_url: "https://example.com/seed.git",
      workspace_root: workspace_root
    )

    try do
      assert {:ok, seeded_projects} = LocalBoard.list_projects()
      seed_project = Enum.find(seeded_projects, &(&1.slug == seed_slug))
      assert seed_project
      assert seed_project.slug == seed_slug
      assert seed_project.name == "Seed Project"
      assert seed_project.directory == seed_directory
      assert seed_project.repo_url == "https://example.com/seed.git"
      assert seed_project.workspace_root == workspace_root
      assert seed_project.enabled == true
      assert %DateTime{} = seed_project.created_at
      assert %DateTime{} = seed_project.updated_at

      assert {:ok, ^seed_project} = LocalBoard.get_project(seed_slug)

      assert {:ok, created_project} =
               LocalBoard.create_project(%{
                 slug: created_slug,
                 name: "Created Project",
                 directory: created_directory,
                 repo_url: "https://example.com/created.git",
                 workspace_root: "/tmp/#{created_slug}-workspace"
               })

      assert created_project.enabled == true
      assert created_project.slug == created_slug

      assert {:ok, edited_project} =
               LocalBoard.update_project(created_slug, %{
                 name: "Edited Project",
                 directory: "#{created_directory}-edited",
                 repo_url: "https://example.com/edited.git",
                 workspace_root: "/tmp/#{created_slug}-workspace-edited"
               })

      assert edited_project.name == "Edited Project"
      assert edited_project.directory == "#{created_directory}-edited"
      assert edited_project.repo_url == "https://example.com/edited.git"
      assert edited_project.workspace_root == "/tmp/#{created_slug}-workspace-edited"

      assert :ok = LocalBoard.disable_project(created_slug)
      assert {:ok, disabled_project} = LocalBoard.get_project(created_slug)
      assert disabled_project.enabled == false

      assert {:ok, projects} = LocalBoard.list_projects()
      assert Enum.any?(projects, &(&1.slug == seed_slug and &1.enabled == true))
      assert Enum.any?(projects, &(&1.slug == created_slug and &1.enabled == false))
    after
      cleanup_projects(database_url, [seed_slug, created_slug])
      Application.put_env(:symphony_elixir, :local_board_store_module, FakeStore)
    end
  end

  test "postgres candidate polling reads active cards from enabled projects only with project context" do
    database_url = local_board_database_url()
    enabled_ready_slug = "registry-ready-#{System.unique_integer([:positive])}"
    enabled_rework_slug = "registry-rework-#{System.unique_integer([:positive])}"
    disabled_slug = "registry-disabled-#{System.unique_integer([:positive])}"
    slugs = [enabled_ready_slug, enabled_rework_slug, disabled_slug]

    Application.delete_env(:symphony_elixir, :local_board_store_module)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: database_url,
      tracker_board_slug: enabled_ready_slug,
      project_slug: enabled_ready_slug,
      project_name: "Registry Ready Project",
      project_directory: "/tmp/#{enabled_ready_slug}",
      tracker_active_states: ["Ready", "Rework"],
      tracker_terminal_states: ["Done", "Cancelled"]
    )

    try do
      assert :ok = SymphonyElixir.LocalBoard.Store.ensure_schema(LocalBoard.store_opts())
      assert {:ok, enabled_ready_project} = LocalBoard.get_project(enabled_ready_slug)

      assert {:ok, enabled_rework_project} =
               LocalBoard.create_project(%{
                 slug: enabled_rework_slug,
                 name: "Registry Rework Project",
                 directory: "/tmp/#{enabled_rework_slug}",
                 workspace_root: "/tmp/#{enabled_rework_slug}-workspace"
               })

      assert {:ok, disabled_project} =
               LocalBoard.create_project(%{
                 slug: disabled_slug,
                 name: "Registry Disabled Project",
                 directory: "/tmp/#{disabled_slug}",
                 workspace_root: "/tmp/#{disabled_slug}-workspace"
               })

      assert :ok = LocalBoard.disable_project(disabled_slug)

      assert {:ok, enabled_ready_card} =
               SymphonyElixir.LocalBoard.Store.create_card(
                 %{
                   id: "card-#{enabled_ready_slug}",
                   identifier: "REG-READY",
                   title: "Ready work from enabled project",
                   state: "Ready"
                 },
                 LocalBoard.store_opts(enabled_ready_project)
               )

      assert {:ok, enabled_rework_card} =
               SymphonyElixir.LocalBoard.Store.create_card(
                 %{
                   id: "card-#{enabled_rework_slug}",
                   identifier: "REG-REWORK",
                   title: "Rework from enabled project",
                   state: "Rework"
                 },
                 LocalBoard.store_opts(enabled_rework_project)
               )

      assert {:ok, disabled_card} =
               SymphonyElixir.LocalBoard.Store.create_card(
                 %{
                   id: "card-#{disabled_slug}",
                   identifier: "REG-DISABLED",
                   title: "Ready work from disabled project",
                   state: "Ready"
                 },
                 LocalBoard.store_opts(disabled_project)
               )

      assert {:ok, issues} = SymphonyElixir.Tracker.fetch_candidate_issues()

      issues_by_id = Map.new(issues, &{&1.id, &1})
      created_issue_ids = [enabled_ready_card.id, enabled_rework_card.id, disabled_card.id]

      returned_created_issue_ids =
        created_issue_ids
        |> Enum.filter(&Map.has_key?(issues_by_id, &1))
        |> Enum.sort()

      assert returned_created_issue_ids == Enum.sort([enabled_ready_card.id, enabled_rework_card.id])

      assert %Issue{state: "Ready", project: %{slug: ^enabled_ready_slug, directory: ready_directory}} =
               Map.fetch!(issues_by_id, enabled_ready_card.id)

      assert ready_directory == "/tmp/#{enabled_ready_slug}"

      assert %Issue{state: "Rework", project: %{slug: ^enabled_rework_slug, directory: rework_directory}} =
               Map.fetch!(issues_by_id, enabled_rework_card.id)

      assert rework_directory == "/tmp/#{enabled_rework_slug}"
      refute Map.has_key?(issues_by_id, disabled_card.id)
    after
      Enum.each(slugs, &cleanup_board(database_url, &1))
      cleanup_projects(database_url, slugs)
      Application.put_env(:symphony_elixir, :local_board_store_module, FakeStore)
    end
  end

  test "postgres cards stay scoped to the selected project board" do
    database_url = local_board_database_url()
    first_slug = "cards-a-#{System.unique_integer([:positive])}"
    second_slug = "cards-b-#{System.unique_integer([:positive])}"

    Application.delete_env(:symphony_elixir, :local_board_store_module)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "local_board",
        tracker_database_url: database_url,
        tracker_board_slug: first_slug,
        project_slug: first_slug,
        project_name: "First Board",
        project_directory: "/tmp/#{first_slug}"
      )

      assert {:ok, first_card} =
               LocalBoard.create_card(%{
                 title: "First board card",
                 state: "Backlog"
               })

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "local_board",
        tracker_database_url: database_url,
        tracker_board_slug: second_slug,
        project_slug: second_slug,
        project_name: "Second Board",
        project_directory: "/tmp/#{second_slug}"
      )

      assert {:ok, second_card} =
               LocalBoard.create_card(%{
                 title: "Second board card",
                 state: "Backlog"
               })

      assert {:ok, [^second_card]} = LocalBoard.list_cards()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "local_board",
        tracker_database_url: database_url,
        tracker_board_slug: first_slug,
        project_slug: first_slug,
        project_name: "First Board",
        project_directory: "/tmp/#{first_slug}"
      )

      assert {:ok, [^first_card]} = LocalBoard.list_cards()
    after
      cleanup_board(database_url, first_slug)
      cleanup_board(database_url, second_slug)
      cleanup_projects(database_url, [first_slug, second_slug])
      Application.put_env(:symphony_elixir, :local_board_store_module, FakeStore)
    end
  end

  test "postgres store reports missing cards when a state update affects zero rows" do
    database_url = local_board_database_url()
    board_slug = "zero-row-move-#{System.unique_integer([:positive])}"
    card_id = "card-#{board_slug}"

    Application.delete_env(:symphony_elixir, :local_board_store_module)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "local_board",
      tracker_database_url: database_url,
      tracker_board_slug: board_slug,
      project_slug: board_slug,
      project_name: "Zero Row Move Project",
      project_directory: "/tmp/#{board_slug}"
    )

    store_opts = LocalBoard.store_opts()

    try do
      assert :ok = SymphonyElixir.LocalBoard.Store.ensure_schema(store_opts)

      assert {:ok, card} =
               SymphonyElixir.LocalBoard.Store.create_card(
                 %{
                   id: card_id,
                   identifier: "ZERO-ROW",
                   title: "Deleted before move",
                   state: "Backlog"
                 },
                 store_opts
               )

      cleanup_board(database_url, board_slug)

      assert {:error, {:local_board_card_not_found, ^card_id}} =
               SymphonyElixir.LocalBoard.Store.update_issue_state(card.id, "Ready", store_opts)
    after
      cleanup_board(database_url, board_slug)
      cleanup_projects(database_url, [board_slug])
      Application.put_env(:symphony_elixir, :local_board_store_module, FakeStore)
    end
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp comment_count(database_url, board_slug, card_id) do
    {:ok, conn} = Postgrex.start_link(SymphonyElixir.LocalBoard.Store.connection_options_for_test(database_url))

    try do
      %{rows: [[count]]} =
        Postgrex.query!(
          conn,
          "SELECT count(*) FROM symphony_board_comments WHERE board_slug = $1 AND card_id = $2",
          [board_slug, card_id]
        )

      count
    after
      GenServer.stop(conn)
    end
  end

  defp cleanup_board(database_url, board_slug) do
    {:ok, conn} = Postgrex.start_link(SymphonyElixir.LocalBoard.Store.connection_options_for_test(database_url))

    try do
      Postgrex.query!(conn, "DELETE FROM symphony_board_cards WHERE board_slug = $1", [board_slug])
    after
      GenServer.stop(conn)
    end
  end

  defp local_board_database_url do
    System.get_env("SYMPHONY_BOARD_DATABASE_URL") || "postgres://postgres@127.0.0.1:5431/symphony_board"
  end

  defp cleanup_projects(database_url, slugs) do
    {:ok, conn} = Postgrex.start_link(SymphonyElixir.LocalBoard.Store.connection_options_for_test(database_url))

    try do
      Postgrex.query!(conn, "DELETE FROM symphony_projects WHERE slug = ANY($1)", [slugs])
    rescue
      error in Postgrex.Error ->
        case error.postgres do
          %{code: :undefined_table} -> :ok
          _ -> reraise(error, __STACKTRACE__)
        end
    after
      GenServer.stop(conn)
    end
  end
end
