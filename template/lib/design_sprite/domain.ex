defmodule DesignSprite.Domain do
  use Ash.Domain

  resources do
    resource(DesignSprite.Resources.Project)
    resource(DesignSprite.Resources.Entry)
    resource(DesignSprite.Resources.Draft)
    resource(DesignSprite.Resources.FileVersion)
  end
end
