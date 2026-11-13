defmodule DesignSprite.Release do
  @moduledoc """
  Release tasks invoked from scripts/run.sh before the server starts:
  `bin/design_sprite eval "DesignSprite.Release.migrate()"`.
  The DDL is the idempotent Store schema (house pattern), so migrate and
  boot can never disagree about the schema.
  """

  def migrate do
    {:ok, _} = Application.ensure_all_started(:design_sprite)
    :ok = DesignSprite.Store.ensure_schema!()
    DesignSprite.Observe.emit("app.migrate", "succeeded", %{})
    :ok
  end
end
