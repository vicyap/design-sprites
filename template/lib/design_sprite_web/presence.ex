defmodule DesignSpriteWeb.Presence do
  @moduledoc """
  Who is in the room. Presence tracks viewers; the Driver seat itself
  is DesignSprite.DriverLock (presence tells the UI who holds it and
  when they vanish).
  """
  use Phoenix.Presence,
    otp_app: :design_sprite,
    pubsub_server: DesignSprite.PubSub

  def topic, do: "project:presence"
end
