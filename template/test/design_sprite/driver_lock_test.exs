defmodule DesignSprite.DriverLockTest do
  use ExUnit.Case, async: false

  alias DesignSprite.{DriverLock, TestSupport}

  setup do
    TestSupport.wipe!()
    :ok
  end

  test "one holder at a time; release frees the seat" do
    assert :ok = DriverLock.acquire("web-a", self())
    assert {:error, :held, "web-a"} = DriverLock.acquire("web-b", self())
    assert DriverLock.holder() == "web-a"
    assert :ok = DriverLock.release("web-a")
    assert DriverLock.holder() == nil
    assert :ok = DriverLock.acquire("web-b", self())
  end

  test "the lock dies with the holder's process (presence-bound)" do
    parent = self()

    pid =
      spawn(fn ->
        :ok = DriverLock.acquire("web-ghost", self())
        send(parent, :acquired)
        Process.sleep(:infinity)
      end)

    assert_receive :acquired
    assert DriverLock.holder() == "web-ghost"

    Process.exit(pid, :kill)
    assert TestSupport.eventually(fn -> DriverLock.holder() == nil end)
  end

  test "an API lease can heartbeat; a stranger cannot" do
    assert :ok = DriverLock.acquire("api-1")
    assert :ok = DriverLock.heartbeat("api-1")
    assert {:error, :not_held} = DriverLock.heartbeat("api-2")
    assert {:error, :held, "api-1"} = DriverLock.acquire("api-2")
  end
end
