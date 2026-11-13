defmodule DesignSpriteWeb.Layouts do
  use DesignSpriteWeb, :html

  embed_templates("layouts/*")

  def title(assigns) do
    case assigns[:project] do
      %{title: t} when is_binary(t) and t != "" -> t
      _ -> "Design Sprite"
    end
  end
end
