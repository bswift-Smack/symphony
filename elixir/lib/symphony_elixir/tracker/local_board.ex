defmodule SymphonyElixir.Tracker.LocalBoard do
  @moduledoc """
  Tracker adapter backed by Symphony's local Postgres board.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.LocalBoard

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    LocalBoard.fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    LocalBoard.cards_by_state(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    LocalBoard.fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    LocalBoard.store_module().create_comment(issue_id, body, LocalBoard.store_opts())
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    LocalBoard.store_module().update_issue_state(issue_id, state_name, LocalBoard.store_opts())
  end
end
