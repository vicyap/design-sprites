defmodule DesignSpriteWeb.DraftController do
  @moduledoc """
  The pagehide safety net for half-answers (v1 fleet pattern): when
  the tab closes inside the autosave debounce window, the browser
  beacons the answer form here and the draft lands server-side.
  Drafts are mutable scratch — never the record — so a beacon can
  never touch a submitted word (the v1 wart class is impossible here
  by construction).
  """
  use DesignSpriteWeb, :controller

  alias DesignSprite.Record

  def save(conn, %{"answer" => %{"question_key" => key} = form}) do
    payload = %{
      "choice" => form["choice"],
      "choices" => form["choices"] || [],
      "other_text" => form["other_text"] || "",
      "dialed_value" => form["dialed_value"],
      "comment" => form["comment"] || ""
    }

    if Record.question_view(key) != nil do
      Record.save_draft(key, payload)
    end

    send_resp(conn, 204, "")
  end

  def save(conn, _params), do: send_resp(conn, 204, "")
end
