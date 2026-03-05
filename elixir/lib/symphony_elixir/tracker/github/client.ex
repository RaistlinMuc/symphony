defmodule SymphonyElixir.Tracker.GitHub.Client do
  @moduledoc """
  GitHub REST client for issue polling and ticket updates.
  """

  require Logger

  alias SymphonyElixir.{Project, Tracker.Issue}

  @per_page 100

  @spec fetch_candidate_issues(Project.t()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(%Project{} = project) do
    with {:ok, _token, headers, base_url, owner, repo} <- request_context(project),
         {:ok, issues} <- fetch_issues(base_url, owner, repo, headers) do
      {:ok, Enum.map(issues, &normalize_issue/1)}
    end
  end

  @spec fetch_issue_states_by_ids(Project.t(), [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(%Project{} = project, issue_ids) when is_list(issue_ids) do
    with {:ok, _token, headers, base_url, owner, repo} <- request_context(project) do
      issue_ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
        case parse_issue_number(issue_id) do
          {:ok, number} ->
            case request(:get, base_url, "/repos/#{owner}/#{repo}/issues/#{number}", headers, nil) do
              {:ok, issue} -> {:cont, {:ok, [normalize_issue(issue) | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, _reason} ->
            {:cont, {:ok, acc}}
        end
      end)
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec create_comment(Project.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(%Project{} = project, issue_id, body)
      when is_binary(issue_id) and is_binary(body) do
    with {:ok, _token, headers, base_url, owner, repo} <- request_context(project),
         {:ok, number} <- parse_issue_number(issue_id),
         {:ok, _} <-
           request(:post, base_url, "/repos/#{owner}/#{repo}/issues/#{number}/comments", headers, %{
             "body" => body
           }) do
      :ok
    end
  end

  @spec update_issue_state(Project.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(%Project{} = project, issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    normalized_state = String.downcase(String.trim(state_name))

    with {:ok, _token, headers, base_url, owner, repo} <- request_context(project),
         {:ok, number} <- parse_issue_number(issue_id),
         true <- normalized_state in ["open", "closed"],
         {:ok, _} <-
           request(:patch, base_url, "/repos/#{owner}/#{repo}/issues/#{number}", headers, %{
             "state" => normalized_state
           }) do
      :ok
    else
      false -> {:error, :invalid_issue_state}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_issues(String.t(), String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, [map()]} | {:error, term()}
  defp fetch_issues(base_url, owner, repo, headers) do
    request(:get, base_url, "/repos/#{owner}/#{repo}/issues", headers, %{"state" => "all", "per_page" => @per_page})
  end

  @spec request_context(Project.t()) ::
          {:ok, String.t(), [{String.t(), String.t()}], String.t(), String.t(), String.t()} | {:error, term()}
  defp request_context(%Project{provider_config: provider_config}) do
    owner = provider_config["owner"]
    repo = provider_config["repo"]
    base_url = provider_config["api_base_url"] || Project.default_github_api_base_url()
    token_env = provider_config["token_env"] || "GITHUB_TOKEN"

    token = System.get_env(token_env)

    cond do
      blank?(owner) ->
        {:error, :missing_github_owner}

      blank?(repo) ->
        {:error, :missing_github_repo}

      blank?(token) ->
        {:error, :missing_github_token}

      true ->
        headers = [
          {"Authorization", "Bearer #{token}"},
          {"Accept", "application/vnd.github+json"},
          {"X-GitHub-Api-Version", "2022-11-28"}
        ]

        {:ok, token, headers, String.trim_trailing(base_url, "/"), owner, repo}
    end
  end

  @spec normalize_issue(map()) :: Issue.t()
  defp normalize_issue(issue) do
    number = to_string(Map.get(issue, "number"))
    is_pr = is_map(Map.get(issue, "pull_request"))

    %Issue{
      id: if(is_pr, do: "pr:" <> number, else: "issue:" <> number),
      identifier: if(is_pr, do: "PR-" <> number, else: "#" <> number),
      title: Map.get(issue, "title") || "",
      description: Map.get(issue, "body"),
      state: Map.get(issue, "state") || "unknown",
      url: Map.get(issue, "html_url"),
      updated_at: parse_datetime(Map.get(issue, "updated_at")),
      branch_name: nil,
      source: if(is_pr, do: :pull_request, else: :issue),
      labels: normalize_labels(Map.get(issue, "labels", []))
    }
  end

  @spec request(atom(), String.t(), String.t(), [{String.t(), String.t()}], map() | nil) ::
          {:ok, map() | [map()]} | {:error, term()}
  defp request(method, base_url, path, headers, payload) do
    url = base_url <> path

    options = [headers: headers, connect_options: [timeout: 30_000]]

    response =
      case method do
        :get -> Req.get(url, Keyword.put(options, :params, payload || %{}))
        :post -> Req.post(url, Keyword.put(options, :json, payload || %{}))
        :patch -> Req.patch(url, Keyword.put(options, :json, payload || %{}))
      end

    case response do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403, headers: headers}} ->
        {:error, github_rate_limit_or_forbidden(headers)}

      {:ok, %{status: 429, headers: headers}} ->
        {:error, {:rate_limited, retry_after_ms(headers)}}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        Logger.error("GitHub API server error status=#{status} body=#{inspect(body)}")
        {:error, {:server_error, status}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @spec github_rate_limit_or_forbidden([{String.t(), String.t()}]) :: term()
  defp github_rate_limit_or_forbidden(headers) do
    remaining = header_value(headers, "x-ratelimit-remaining")

    if remaining == "0" do
      {:rate_limited, retry_after_ms(headers)}
    else
      :forbidden
    end
  end

  @spec retry_after_ms([{String.t(), String.t()}]) :: non_neg_integer()
  defp retry_after_ms(headers) do
    case header_value(headers, "retry-after") do
      nil ->
        case header_value(headers, "x-ratelimit-reset") do
          nil ->
            60_000

          value ->
            case Integer.parse(value) do
              {reset_unix, _} ->
                now_unix = DateTime.utc_now() |> DateTime.to_unix()
                max(reset_unix - now_unix, 1) * 1_000

              _ ->
                60_000
            end
        end

      value ->
        case Integer.parse(value) do
          {seconds, _} -> max(seconds, 1) * 1_000
          _ -> 60_000
        end
    end
  end

  @spec header_value([{String.t(), String.t()}], String.t()) :: String.t() | nil
  defp header_value(headers, key) do
    headers
    |> Enum.find_value(fn {k, v} -> if String.downcase(k) == key, do: v end)
  end

  @spec normalize_labels(term()) :: [String.t()]
  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> String.downcase(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_labels(_), do: []

  @spec parse_issue_number(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp parse_issue_number(issue_id) when is_binary(issue_id) do
    case String.split(issue_id, ":", parts: 2) do
      ["issue", number] -> {:ok, number}
      ["pr", number] -> {:ok, number}
      _ -> {:error, :invalid_issue_id}
    end
  end

  @spec parse_datetime(term()) :: DateTime.t() | nil
  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  @spec blank?(term()) :: boolean()
  defp blank?(nil), do: true

  defp blank?(value) when is_binary(value) do
    String.trim(value) == ""
  end

  defp blank?(_), do: false
end
