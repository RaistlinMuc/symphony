defmodule SymphonyElixir.Tracker.GitHub.Auth do
  @moduledoc """
  Resolves GitHub API credentials from environment or local `gh` CLI auth.
  """

  @spec token(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def token(token_env) when is_binary(token_env) do
    case System.get_env(token_env) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          gh_auth_token()
        else
          {:ok, trimmed}
        end

      _ ->
        gh_auth_token()
    end
  end

  def token(_token_env), do: gh_auth_token()

  @spec available?(String.t() | nil) :: boolean()
  def available?(token_env) do
    match?({:ok, _token}, token(token_env))
  end

  @spec gh_auth_token() :: {:ok, String.t()} | {:error, term()}
  defp gh_auth_token do
    case System.find_executable("gh") do
      nil ->
        {:error, :missing_github_token}

      gh ->
        gh
        |> System.cmd(["auth", "token"], stderr_to_stdout: true)
        |> normalize_gh_auth_token()
    end
  end

  defp normalize_gh_auth_token({output, 0}) do
    case String.trim(output) do
      "" -> {:error, :missing_github_token}
      token -> {:ok, token}
    end
  end

  defp normalize_gh_auth_token({_output, _status}), do: {:error, :missing_github_token}
end
