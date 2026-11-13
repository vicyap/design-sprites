defmodule DesignSprite.AI.Client do
  @moduledoc """
  The one adapter between the AI driver and the model provider
  (software-design checklist: external calls sit behind one adapter
  each). The production implementation calls the model through the
  Sprites gateway conn:anthropic connection via ReqLLM's streaming
  structured-output call (Victor's canonical package list: LLM
  client = ReqLLM, structured output via its object calls); tests
  use the stub.

  The contract returns the ALREADY-PARSED reply object (string keys).
  Transport and shape failures come back as {:error, _}; semantic
  validation of the reply stays in the driver.
  """

  @callback generate(system :: String.t(), user :: String.t(), schema :: map()) ::
              {:ok, map()} | {:error, term()}

  def impl do
    Application.get_env(:design_sprite, :ai_adapter, DesignSprite.AI.GatewayClient)
  end

  def generate(system, user, schema), do: impl().generate(system, user, schema)
end
