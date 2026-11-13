defmodule DesignSprite.AI.ErrorInfoTest do
  use ExUnit.Case, async: true

  alias DesignSprite.AI.ErrorInfo

  @billing_body ~s({"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."},"request_id":"req_abc"})

  test "an Anthropic billing 400 surfaces status, type and the full message (F5)" do
    reason =
      struct(ReqLLM.Error.API.Response,
        status: 400,
        reason: "invalid request",
        response_body: @billing_body
      )

    fields = ErrorInfo.fields({:ai_call_failed, reason})

    assert fields["error"] == "ai_call_failed"
    assert fields["error_status"] == 400
    assert fields["error_type"] == "invalid_request_error"
    assert fields["error_message"] =~ "credit balance is too low"
    # The whole point of F5: the provider message is NOT cut at 80 chars.
    assert byte_size(fields["error_message"]) > 80
  end

  test "the unwrapped error is labelled by its struct class" do
    reason = struct(ReqLLM.Error.API.Response, status: 500, reason: "boom", response_body: nil)
    fields = ErrorInfo.fields(reason)
    assert fields["error"] == "ReqLLM.Error.API.Response"
    assert fields["error_status"] == 500
    assert fields["error_message"] == "boom"
  end

  test "a decoded Anthropic error body (plain map) yields type and message" do
    fields =
      ErrorInfo.fields(%{"error" => %{"type" => "overloaded_error", "message" => "Overloaded"}})

    assert fields["error_type"] == "overloaded_error"
    assert fields["error_message"] == "Overloaded"
  end

  test "a response_body that is already a decoded map is read directly" do
    reason = %{
      status: 429,
      response_body: %{"error" => %{"type" => "rate_limit_error", "message" => "Slow down"}}
    }

    fields = ErrorInfo.fields(reason)
    assert fields["error_status"] == 429
    assert fields["error_type"] == "rate_limit_error"
    assert fields["error_message"] == "Slow down"
  end

  test "a provider_code surfaces as the error type when no body is present" do
    reason = struct(ReqLLM.Error.API.Request, status: 429, provider_code: "rate_limit")
    assert ErrorInfo.fields(reason)["error_type"] == "rate_limit"
  end

  test "our own atoms label themselves and carry no fabricated metadata" do
    assert ErrorInfo.fields(:turn_timeout) == %{"error" => "turn_timeout"}
    assert ErrorInfo.fields(:reply_not_json) == %{"error" => "reply_not_json"}
    assert ErrorInfo.fields({:task_exit, :killed}) == %{"error" => "task_exit"}
  end

  test "a transport-style atom reason surfaces as the type" do
    assert ErrorInfo.fields(%{reason: :timeout})["error_type"] == "timeout"
  end

  test "the provider message is capped, not truncated at 80" do
    long = String.duplicate("x", 500)
    fields = ErrorInfo.fields(%{"error" => %{"type" => "api_error", "message" => long}})
    assert byte_size(fields["error_message"]) == 300
  end
end
