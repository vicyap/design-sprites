defmodule DesignSprite.Resources.Project do
  @moduledoc """
  The one Project this sprite hosts. Created once from the opening
  text box ("What do you want to design?" — the `want`). `status` moves
  open -> committed exactly once, by a deliberate human press of the
  Commit button; committed freezes design content read-only (the
  Decided-for-you log stays appendable by design — those are entries,
  not project fields).
  """

  use Ash.Resource,
    otp_app: :design_sprite,
    domain: DesignSprite.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("projects")
    repo(DesignSprite.Repo)
  end

  attributes do
    integer_primary_key(:id)
    attribute(:want, :string, allow_nil?: false)
    attribute(:title, :string)
    attribute(:status, :string, allow_nil?: false, default: "open")
    # Verbatim ISO strings (house pattern: timestamps round-trip exact).
    attribute(:committed_at, :string)
    attribute(:created_at, :string, allow_nil?: false)
  end

  validations do
    validate(one_of(:status, ["open", "committed"]),
      message: "status must be open or committed"
    )
  end

  actions do
    defaults([:read])

    create :create do
      accept([:want, :title, :status, :committed_at, :created_at])
    end

    update :update do
      accept([:title, :status, :committed_at])
    end
  end
end
