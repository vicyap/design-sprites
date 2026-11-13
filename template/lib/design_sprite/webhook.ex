defmodule DesignSprite.Webhook do
  @moduledoc """
  The optional Commit webhook (contract item 8): a fire-and-forget
  POST when a Project Commits. Notification is never email. The
  payload carries ids and timestamps only — never content — so a
  receiver re-reads the Project through the API, the source of truth.

  Config: COMMIT_WEBHOOK_URL / COMMIT_WEBHOOK_TOKEN env (unset = no
  webhook; that is a configuration, not an error).
  """

  alias DesignSprite.Observe

  def commit(project) do
    case Application.get_env(:design_sprite, :webhook_url) do
      url when is_binary(url) and url != "" ->
        Task.Supervisor.start_child(DesignSprite.TaskSupervisor, fn -> post(url, project) end)
        :ok

      _ ->
        :ok
    end
  end

  defp post(url, project) do
    payload = %{
      "event" => "project.committed",
      "sprite" => Application.get_env(:design_sprite, :sprite_name),
      "project_id" => project.id,
      "committed_at" => project.committed_at
    }

    headers =
      case Application.get_env(:design_sprite, :webhook_token) do
        token when is_binary(token) and token != "" ->
          [{"authorization", "Bearer " <> token}]

        _ ->
          []
      end

    case Req.post(url, json: payload, headers: headers, retry: false, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        Observe.emit("webhook.commit", "succeeded", %{})

      {:ok, %Req.Response{status: status}} ->
        Observe.emit("webhook.commit", "failed", %{reason: "http_status", status: status})

      {:error, _reason} ->
        Observe.emit("webhook.commit", "failed", %{reason: "transport"})
    end
  end
end
