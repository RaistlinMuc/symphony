defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Provider-neutral issue/pull-request model used by multi-project orchestration.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :state,
    :url,
    :updated_at,
    :branch_name,
    :source,
    labels: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          identifier: String.t(),
          title: String.t(),
          description: String.t() | nil,
          state: String.t(),
          url: String.t() | nil,
          updated_at: DateTime.t() | nil,
          branch_name: String.t() | nil,
          source: :issue | :pull_request,
          labels: [String.t()]
        }
end
