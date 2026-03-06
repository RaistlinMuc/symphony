defmodule SymphonyElixir.Tracker.GitLab.Client do
  @moduledoc """
  GitLab REST client for issue/merge-request polling and updates.
  """

  require Logger

  alias SymphonyElixir.{Project, Tracker.Issue}

  @per_page 100

  @spec fetch_candidate_issues(Project.t()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(%Project{} = project) do
    with {:ok, headers, base_url, project_ref} <- request_context(project),
         {:ok, issues} <- request(:get, base_url, "/api/v4/projects/#{project_ref}/issues", headers, %{"state" => "all", "per_page" => @per_page}),
         {:ok, merge_requests} <-
           request(:get, base_url, "/api/v4/projects/#{project_ref}/merge_requests", headers, %{"state" => "all", "per_page" => @per_page}) do
      normalized = Enum.map(issues, &normalize_issue/1) ++ Enum.map(merge_requests, &normalize_merge_request/1)
      {:ok, normalized}
    end
  end

  @spec fetch_issue_states_by_ids(Project.t(), [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(%Project{} = project, issue_ids) when is_list(issue_ids) do
    with {:ok, headers, base_url, project_ref} <- request_context(project) do
      fetch_issue_states(issue_ids, headers, base_url, project_ref)
    end
  end

  @spec create_comment(Project.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(%Project{} = project, issue_id, body)
      when is_binary(issue_id) and is_binary(body) do
    with {:ok, headers, base_url, project_ref} <- request_context(project),
         {:ok, type, iid} <- parse_issue_key(issue_id),
         path <- notes_path(project_ref, type, iid),
         {:ok, _} <- request(:post, base_url, path, headers, %{"body" => body}) do
      :ok
    end
  end

  @spec replace_labels(Project.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def replace_labels(%Project{} = project, issue_id, labels)
      when is_binary(issue_id) and is_list(labels) do
    with {:ok, headers, base_url, project_ref} <- request_context(project),
         {:ok, type, iid} <- parse_issue_key(issue_id),
         path <- update_path(project_ref, type, iid),
         {:ok, _} <- request(:put, base_url, path, headers, %{"labels" => Enum.join(labels, ",")}) do
      :ok
    end
  end

  @spec update_issue_state(Project.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(%Project{} = project, issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    state_event =
      case String.downcase(String.trim(state_name)) do
        "closed" -> "close"
        "open" -> "reopen"
        "opened" -> "reopen"
        _ -> nil
      end

    with {:ok, headers, base_url, project_ref} <- request_context(project),
         {:ok, type, iid} <- parse_issue_key(issue_id),
         true <- not is_nil(state_event),
         path <- update_path(project_ref, type, iid),
         {:ok, _} <- request(:put, base_url, path, headers, %{"state_event" => state_event}) do
      :ok
    else
      false -> {:error, :invalid_issue_state}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec request_context(Project.t()) :: {:ok, [{String.t(), String.t()}], String.t(), String.t()} | {:error, term()}
  defp request_context(%Project{provider_config: provider_config}) do
    token_env = provider_config["token_env"] || "GITLAB_TOKEN"
    token = System.get_env(token_env)
    base_url = provider_config["base_url"] || Project.default_gitlab_base_url()

    project_ref =
      cond do
        not blank?(provider_config["project_id"]) -> provider_config["project_id"]
        not blank?(provider_config["project_path"]) -> URI.encode_www_form(provider_config["project_path"])
        true -> nil
      end

    cond do
      blank?(token) ->
        {:error, :missing_gitlab_token}

      blank?(project_ref) ->
        {:error, :missing_gitlab_project_ref}

      true ->
        headers = [
          {"PRIVATE-TOKEN", token},
          {"Content-Type", "application/json"}
        ]

        {:ok, headers, String.trim_trailing(base_url, "/"), project_ref}
    end
  end

  @spec request(atom(), String.t(), String.t(), [{String.t(), String.t()}], map() | nil) ::
          {:ok, map() | [map()]} | {:error, term()}
  defp request(method, base_url, path, headers, payload) do
    base_url
    |> Kernel.<>(path)
    |> perform_request(method, headers, payload)
    |> handle_response()
  end

  defp fetch_issue_states(issue_ids, headers, base_url, project_ref) do
    issue_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
      case fetch_issue_state(issue_id, headers, base_url, project_ref) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_issue_state(issue_id, headers, base_url, project_ref) do
    with {:ok, type, iid} <- parse_issue_key(issue_id),
         path <- update_path(project_ref, type, iid),
         {:ok, payload} <- request(:get, base_url, path, headers, nil) do
      {:ok, normalize_issue_payload(type, payload)}
    else
      {:error, :invalid_issue_id} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_request(url, :get, headers, payload) do
    Req.get(url, request_options(headers, :params, payload))
  end

  defp perform_request(url, :post, headers, payload) do
    Req.post(url, request_options(headers, :json, payload))
  end

  defp perform_request(url, :put, headers, payload) do
    Req.put(url, request_options(headers, :json, payload))
  end

  defp request_options(headers, payload_key, payload) do
    [headers: headers, connect_options: [timeout: 30_000]]
    |> Keyword.put(payload_key, payload || %{})
  end

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_response({:ok, %{status: 403}}), do: {:error, :forbidden}

  defp handle_response({:ok, %{status: 429, headers: headers}}) do
    {:error, {:rate_limited, retry_after_ms(headers)}}
  end

  defp handle_response({:ok, %{status: status, body: body}}) when status >= 500 do
    Logger.error("GitLab API server error status=#{status} body=#{inspect(body)}")
    {:error, {:server_error, status}}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    {:error, {:http_error, status, body}}
  end

  defp handle_response({:error, reason}), do: {:error, {:request_failed, reason}}

  defp normalize_issue_payload(:issue, issue), do: normalize_issue(issue)
  defp normalize_issue_payload(:merge_request, merge_request), do: normalize_merge_request(merge_request)

  @spec retry_after_ms([{String.t(), String.t()}]) :: non_neg_integer()
  defp retry_after_ms(headers) do
    headers
    |> Enum.find_value(fn {key, value} -> if String.downcase(key) == "retry-after", do: value end)
    |> case do
      nil ->
        60_000

      value ->
        case Integer.parse(value) do
          {seconds, _} -> max(seconds, 1) * 1_000
          _ -> 60_000
        end
    end
  end

  @spec normalize_issue(map()) :: Issue.t()
  defp normalize_issue(issue) do
    iid = to_string(Map.get(issue, "iid"))

    %Issue{
      id: "issue:" <> iid,
      identifier: "#" <> iid,
      title: Map.get(issue, "title") || "",
      description: Map.get(issue, "description"),
      state: Map.get(issue, "state") || "unknown",
      url: Map.get(issue, "web_url"),
      updated_at: parse_datetime(Map.get(issue, "updated_at")),
      branch_name: nil,
      source: :issue,
      labels: normalize_labels(Map.get(issue, "labels", []))
    }
  end

  @spec normalize_merge_request(map()) :: Issue.t()
  defp normalize_merge_request(merge_request) do
    iid = to_string(Map.get(merge_request, "iid"))

    %Issue{
      id: "mr:" <> iid,
      identifier: "MR!" <> iid,
      title: Map.get(merge_request, "title") || "",
      description: Map.get(merge_request, "description"),
      state: Map.get(merge_request, "state") || "unknown",
      url: Map.get(merge_request, "web_url"),
      updated_at: parse_datetime(Map.get(merge_request, "updated_at")),
      branch_name: Map.get(merge_request, "source_branch"),
      source: :pull_request,
      labels: normalize_labels(Map.get(merge_request, "labels", []))
    }
  end

  @spec normalize_labels(term()) :: [String.t()]
  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      value when is_binary(value) -> String.downcase(value)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_labels(_), do: []

  @spec parse_issue_key(String.t()) :: {:ok, :issue | :merge_request, String.t()} | {:error, term()}
  defp parse_issue_key(issue_id) do
    case String.split(issue_id, ":", parts: 2) do
      ["issue", iid] -> {:ok, :issue, iid}
      ["mr", iid] -> {:ok, :merge_request, iid}
      _ -> {:error, :invalid_issue_id}
    end
  end

  @spec notes_path(String.t(), :issue | :merge_request, String.t()) :: String.t()
  defp notes_path(project_ref, :issue, iid), do: "/api/v4/projects/#{project_ref}/issues/#{iid}/notes"
  defp notes_path(project_ref, :merge_request, iid), do: "/api/v4/projects/#{project_ref}/merge_requests/#{iid}/notes"

  @spec update_path(String.t(), :issue | :merge_request, String.t()) :: String.t()
  defp update_path(project_ref, :issue, iid), do: "/api/v4/projects/#{project_ref}/issues/#{iid}"

  defp update_path(project_ref, :merge_request, iid),
    do: "/api/v4/projects/#{project_ref}/merge_requests/#{iid}"

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
