defmodule DesignSprite.Resources.FileVersion do
  @moduledoc """
  The version index for project files. Bytes live on disk
  (data/files/<path>, history under data/files/.history/<path>/v<n>);
  one row per version records who wrote it and its sha256, so the
  file explorer and the export bundle can prove what they serve.
  """

  use Ash.Resource,
    otp_app: :design_sprite,
    domain: DesignSprite.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("file_versions")
    repo(DesignSprite.Repo)
  end

  attributes do
    integer_primary_key(:id)
    attribute(:path, :string, allow_nil?: false)
    attribute(:version, :integer, allow_nil?: false)
    attribute(:sha256, :string, allow_nil?: false)
    attribute(:bytes, :integer, allow_nil?: false)
    # human | ai | agent | system
    attribute(:actor, :string, allow_nil?: false)
    attribute(:created_at, :string, allow_nil?: false)
  end

  identities do
    identity(:unique_path_version, [:path, :version])
  end

  actions do
    defaults([:read])

    create :create do
      accept([:path, :version, :sha256, :bytes, :actor, :created_at])
    end
  end
end
