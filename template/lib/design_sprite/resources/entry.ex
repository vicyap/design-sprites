defmodule DesignSprite.Resources.Entry do
  @moduledoc """
  One row of the append-only record. Kinds:

  - "want"        the opening ask (body = the want, verbatim)
  - "message"     a chat message (body = verbatim text; payload may
                  carry "elements": inspector chips attached)
  - "question"    a question card (payload = the full question incl.
                  the AI's prediction — see DesignSprite.Record)
  - "answer"      an answer to a question (payload.question_key, choice
                  / choices, other_text, comment — all verbatim)
  - "score"       a scored prediction (payload.question_key, result
                  hit|miss, reason, provisional flag)
  - "skip"        the Driver skipped a question (payload.question_key);
                  the prediction stands, no score is recorded
  - "strike"      the Driver said "out of scope" (payload.question_key);
                  the axis is removed from the map
  - "model"       a model re-derivation landed (payload.version,
                  payload.path = model.md)
  - "artifact"    an artifact version landed (payload.name, version)
  - "file"        any other versioned file write (payload.path, version)
  - "decision"    a Decided-for-you entry (body = the decision text;
                  the only kind appendable after Commit)
  - "system"      machine notes (sharpness declarations, driver
                  failures) — body is safe to show, never user content

  There is deliberately NO update or destroy action. Append-only is
  enforced by the action surface, not by convention.
  """

  use Ash.Resource,
    otp_app: :design_sprite,
    domain: DesignSprite.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("entries")
    repo(DesignSprite.Repo)
  end

  attributes do
    integer_primary_key(:id)
    attribute(:seq, :integer, allow_nil?: false)
    attribute(:kind, :string, allow_nil?: false)
    # human | ai | agent | system
    attribute(:actor, :string, allow_nil?: false)
    attribute(:body, :string)
    attribute(:payload, :map)
    attribute(:created_at, :string, allow_nil?: false)
  end

  identities do
    identity(:unique_seq, [:seq])
  end

  validations do
    validate(
      one_of(:kind, ~w(want message question answer score skip strike model artifact file decision system)),
      message: "unknown entry kind"
    )

    validate(one_of(:actor, ~w(human ai agent system)),
      message: "unknown entry actor"
    )
  end

  actions do
    defaults([:read])

    create :create do
      accept([:seq, :kind, :actor, :body, :payload, :created_at])
    end
  end
end
