defmodule DesignSprite.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Before anything can crash: crash reports must not carry entry
    # content into the log (see DesignSprite.LogScrub).
    :ok = DesignSprite.LogScrub.install()

    children =
      [
        DesignSprite.Repo,
        {Phoenix.PubSub, name: DesignSprite.PubSub},
        DesignSpriteWeb.Presence,
        DesignSprite.RecordWriter,
        DesignSprite.DriverLock,
        {Task.Supervisor, name: DesignSprite.TaskSupervisor},
        DesignSprite.AI.Driver,
        DesignSpriteWeb.Endpoint
      ] ++ stub_children()

    opts = [strategy: :one_for_one, name: DesignSprite.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      :ok = DesignSprite.Store.ensure_schema!()
      :ok = DesignSprite.Token.ensure!()
      DesignSprite.Observe.emit("app.boot", "succeeded", %{})
      {:ok, pid}
    end
  end

  # The stub AI adapter runs only when configured (tests / local dev);
  # production sprites use the gateway client and never start it.
  defp stub_children do
    if DesignSprite.AI.Client.impl() == DesignSprite.AI.StubClient do
      [DesignSprite.AI.StubClient]
    else
      []
    end
  end
end
