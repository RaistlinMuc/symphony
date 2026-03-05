defmodule SymphonyElixir.Project do
  @moduledoc """
  Project configuration model for multi-project orchestration.
  """

  @default_github_api_base_url "https://api.github.com"
  @default_gitlab_base_url "https://git.pq-computers.com"
  @default_mode "build_only"
  @default_build_timeout_ms 900_000

  defstruct [
    :id,
    :name,
    :repo_path,
    :enabled,
    :mode,
    :provider,
    :provider_config,
    :build,
    :ticket_mapping,
    :created_at,
    :updated_at,
    :last_changed_at
  ]

  @type provider :: String.t()
  @type mode :: String.t()

  @type provider_config :: %{
          optional(String.t()) => term()
        }

  @type build_config :: %{
          optional(String.t()) => term()
        }

  @type ticket_mapping :: %{
          optional(String.t()) => term()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          repo_path: String.t(),
          enabled: boolean(),
          mode: mode(),
          provider: provider(),
          provider_config: provider_config(),
          build: build_config(),
          ticket_mapping: ticket_mapping(),
          created_at: String.t(),
          updated_at: String.t(),
          last_changed_at: String.t() | nil
        }

  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    with {:ok, id} <- required_string(map, "id"),
         {:ok, name} <- required_string(map, "name"),
         {:ok, repo_path} <- required_string(map, "repo_path"),
         {:ok, provider} <- provider_value(map),
         {:ok, mode} <- mode_value(map) do
      project = %__MODULE__{
        id: id,
        name: name,
        repo_path: Path.expand(repo_path),
        enabled: Map.get(map, "enabled", true) == true,
        mode: mode,
        provider: provider,
        provider_config: normalize_provider_config(provider, Map.get(map, "provider_config", %{})),
        build: normalize_build(Map.get(map, "build", %{})),
        ticket_mapping: normalize_ticket_mapping(provider, Map.get(map, "ticket_mapping", %{})),
        created_at: map_timestamp(map, "created_at"),
        updated_at: map_timestamp(map, "updated_at"),
        last_changed_at: optional_string(map, "last_changed_at")
      }

      {:ok, project}
    end
  end

  def from_map(_), do: {:error, :invalid_project_payload}

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    now = timestamp_now()

    attrs
    |> Map.put_new("id", random_id())
    |> Map.put_new("enabled", true)
    |> Map.put_new("mode", @default_mode)
    |> Map.put_new("provider_config", %{})
    |> Map.put_new("build", %{})
    |> Map.put_new("ticket_mapping", %{})
    |> Map.put_new("created_at", now)
    |> Map.put("updated_at", now)
    |> from_map()
  end

  @spec update(t(), map()) :: {:ok, t()} | {:error, term()}
  def update(%__MODULE__{} = project, attrs) when is_map(attrs) do
    map = to_map(project)

    merged =
      map
      |> Map.merge(attrs)
      |> Map.put("id", project.id)
      |> Map.put("created_at", project.created_at)
      |> Map.put("updated_at", timestamp_now())

    from_map(merged)
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = project) do
    %{
      "id" => project.id,
      "name" => project.name,
      "repo_path" => project.repo_path,
      "enabled" => project.enabled,
      "mode" => project.mode,
      "provider" => project.provider,
      "provider_config" => project.provider_config,
      "build" => project.build,
      "ticket_mapping" => project.ticket_mapping,
      "created_at" => project.created_at,
      "updated_at" => project.updated_at,
      "last_changed_at" => project.last_changed_at
    }
  end

  @spec readiness(t()) :: %{ready: boolean(), missing_fields: [String.t()]}
  def readiness(%__MODULE__{} = project) do
    missing_fields =
      []
      |> maybe_add_missing(project.name == "", "name")
      |> maybe_add_missing(project.repo_path == "", "repo_path")
      |> maybe_add_missing(not File.exists?(project.repo_path), "repo_path_exists")
      |> maybe_add_missing(not git_repo?(project.repo_path), "git_repository")
      |> provider_missing(project)
      |> build_missing(project)

    %{ready: missing_fields == [], missing_fields: missing_fields}
  end

  @spec active_states(t()) :: [String.t()]
  def active_states(%__MODULE__{} = project) do
    profile = mapping_defaults(project.provider)

    project.ticket_mapping
    |> Map.get("overrides", %{})
    |> Map.get("active_states", profile["active_states"])
    |> normalize_string_list(profile["active_states"])
  end

  @spec terminal_states(t()) :: [String.t()]
  def terminal_states(%__MODULE__{} = project) do
    profile = mapping_defaults(project.provider)

    project.ticket_mapping
    |> Map.get("overrides", %{})
    |> Map.get("terminal_states", profile["terminal_states"])
    |> normalize_string_list(profile["terminal_states"])
  end

  @spec labels_include(t()) :: [String.t()]
  def labels_include(%__MODULE__{} = project) do
    project.ticket_mapping
    |> Map.get("overrides", %{})
    |> Map.get("labels_include", [])
    |> normalize_string_list([])
    |> Enum.map(&String.downcase/1)
  end

  @spec labels_exclude(t()) :: [String.t()]
  def labels_exclude(%__MODULE__{} = project) do
    project.ticket_mapping
    |> Map.get("overrides", %{})
    |> Map.get("labels_exclude", [])
    |> normalize_string_list([])
    |> Enum.map(&String.downcase/1)
  end

  @spec default_github_api_base_url() :: String.t()
  def default_github_api_base_url, do: @default_github_api_base_url

  @spec default_gitlab_base_url() :: String.t()
  def default_gitlab_base_url, do: @default_gitlab_base_url

  defp provider_value(map) do
    provider =
      map
      |> Map.get("provider")
      |> optional_string_value()

    case provider do
      "github" -> {:ok, "github"}
      "gitlab" -> {:ok, "gitlab"}
      _ -> {:error, :invalid_provider}
    end
  end

  defp mode_value(map) do
    mode =
      map
      |> Map.get("mode", @default_mode)
      |> optional_string_value()

    case mode do
      "build_only" -> {:ok, "build_only"}
      "full_agent" -> {:ok, "full_agent"}
      _ -> {:error, :invalid_mode}
    end
  end

  defp normalize_provider_config("github", raw) when is_map(raw) do
    %{
      "owner" => optional_string(raw, "owner"),
      "repo" => optional_string(raw, "repo"),
      "api_base_url" => optional_string(raw, "api_base_url") || @default_github_api_base_url,
      "token_env" => optional_string(raw, "token_env") || "GITHUB_TOKEN"
    }
  end

  defp normalize_provider_config("gitlab", raw) when is_map(raw) do
    %{
      "base_url" => optional_string(raw, "base_url") || @default_gitlab_base_url,
      "project_path" => optional_string(raw, "project_path"),
      "project_id" => optional_string(raw, "project_id"),
      "token_env" => optional_string(raw, "token_env") || "GITLAB_TOKEN"
    }
  end

  defp normalize_provider_config(_, _), do: %{}

  defp normalize_build(raw) when is_map(raw) do
    %{
      "commands" => normalize_string_list(Map.get(raw, "commands", []), []),
      "workdir" => optional_string(raw, "workdir"),
      "timeout_ms" => non_negative_integer(Map.get(raw, "timeout_ms"), @default_build_timeout_ms)
    }
  end

  defp normalize_build(_), do: %{"commands" => [], "workdir" => nil, "timeout_ms" => @default_build_timeout_ms}

  defp normalize_ticket_mapping(provider, raw) when is_map(raw) do
    profile =
      raw
      |> Map.get("defaults_profile")
      |> optional_string_value()
      |> case do
        nil -> default_profile(provider)
        value -> value
      end

    overrides = Map.get(raw, "overrides", %{})

    %{
      "defaults_profile" => profile,
      "overrides" => %{
        "active_states" => normalize_string_list(Map.get(overrides, "active_states"), nil),
        "terminal_states" => normalize_string_list(Map.get(overrides, "terminal_states"), nil),
        "labels_include" => normalize_string_list(Map.get(overrides, "labels_include"), []),
        "labels_exclude" => normalize_string_list(Map.get(overrides, "labels_exclude"), []),
        "pr_event_rules" => normalize_pr_event_rules(Map.get(overrides, "pr_event_rules", %{}))
      }
    }
  end

  defp normalize_ticket_mapping(provider, _), do: normalize_ticket_mapping(provider, %{})

  defp default_profile("github"), do: "github_default"
  defp default_profile("gitlab"), do: "gitlab_default"

  defp mapping_defaults("github"),
    do: %{"active_states" => ["open"], "terminal_states" => ["closed"]}

  defp mapping_defaults("gitlab"),
    do: %{"active_states" => ["opened"], "terminal_states" => ["closed"]}

  defp normalize_pr_event_rules(value) when is_map(value) do
    %{
      "watch_reviews" => Map.get(value, "watch_reviews", true) == true,
      "watch_commits" => Map.get(value, "watch_commits", true) == true,
      "watch_checks" => Map.get(value, "watch_checks", true) == true
    }
  end

  defp normalize_pr_event_rules(_),
    do: %{"watch_reviews" => true, "watch_commits" => true, "watch_checks" => true}

  defp provider_missing(missing_fields, %__MODULE__{provider: "github", provider_config: provider_config}) do
    missing_fields
    |> maybe_add_missing(blank?(provider_config["owner"]), "provider_config.owner")
    |> maybe_add_missing(blank?(provider_config["repo"]), "provider_config.repo")
    |> maybe_add_missing(blank?(provider_config["token_env"]), "provider_config.token_env")
    |> maybe_add_missing(blank?(System.get_env(provider_config["token_env"] || "")), "provider_config.token")
  end

  defp provider_missing(missing_fields, %__MODULE__{provider: "gitlab", provider_config: provider_config}) do
    missing_project = blank?(provider_config["project_path"]) and blank?(provider_config["project_id"])

    missing_fields
    |> maybe_add_missing(missing_project, "provider_config.project_path_or_id")
    |> maybe_add_missing(blank?(provider_config["token_env"]), "provider_config.token_env")
    |> maybe_add_missing(blank?(System.get_env(provider_config["token_env"] || "")), "provider_config.token")
  end

  defp provider_missing(missing_fields, _project), do: missing_fields

  defp build_missing(missing_fields, %__MODULE__{build: build}) do
    maybe_add_missing(missing_fields, not is_list(build["commands"]), "build.commands")
  end

  defp maybe_add_missing(list, true, field), do: list ++ [field]
  defp maybe_add_missing(list, false, _field), do: list

  defp map_timestamp(map, key) do
    optional_string(map, key) || timestamp_now()
  end

  defp required_string(map, key) do
    case optional_string(map, key) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  defp optional_string(map, key) when is_map(map) do
    map
    |> Map.get(key)
    |> optional_string_value()
  end

  defp optional_string_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp optional_string_value(_), do: nil

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp non_negative_integer(_value, default), do: default

  defp normalize_string_list(nil, default), do: default

  defp normalize_string_list(list, _default) when is_list(list) do
    list
    |> Enum.map(&optional_string_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(value, default) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> default
      parsed -> parsed
    end
  end

  defp normalize_string_list(_value, default), do: default

  defp blank?(nil), do: true

  defp blank?(value) when is_binary(value) do
    String.trim(value) == ""
  end

  defp blank?(_value), do: false

  defp git_repo?(path) when is_binary(path) do
    File.dir?(Path.join(path, ".git")) or
      match?({_, 0}, System.cmd("git", ["rev-parse", "--is-inside-work-tree"], cd: path, stderr_to_stdout: true))
  rescue
    _error ->
      false
  end

  @spec random_id() :: String.t()
  def random_id do
    "prj_" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
  end

  @spec timestamp_now() :: String.t()
  def timestamp_now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
