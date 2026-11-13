defmodule DesignSprite.Resources.Draft do
  @moduledoc """
  A half-answer: the autosaved form state of one unanswered question
  card. Drafts are mutable and are NOT part of the record — when the
  question is answered, the answer lands as an append-only entry and
  the draft is destroyed. A draft surviving a restart is how a
  half-answer persists when the Driver's tab dies (the Driver lock
  dies with presence; the draft stays).
  """

  use Ash.Resource,
    otp_app: :design_sprite,
    domain: DesignSprite.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("drafts")
    repo(DesignSprite.Repo)
  end

  attributes do
    integer_primary_key(:id)
    attribute(:question_key, :string, allow_nil?: false)
    attribute(:payload, :map)
    attribute(:updated_at, :string, allow_nil?: false)
  end

  identities do
    identity(:unique_question, [:question_key])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:question_key, :payload, :updated_at])
      upsert?(true)
      upsert_identity(:unique_question)
      upsert_fields([:payload, :updated_at])
    end

    update :update do
      accept([:payload, :updated_at])
    end
  end
end
