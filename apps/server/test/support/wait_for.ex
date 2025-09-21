# test/support/wait_for.ex
defmodule WaitFor do
  @moduledoc """
  Helper for waiting for async conditions in tests
  """

  def wait_for(condition, timeout \\ 1000) do
    wait_until = System.monotonic_time(:millisecond) + timeout
    do_wait_for(condition, wait_until)
  end

  defp do_wait_for(condition, wait_until) do
    if System.monotonic_time(:millisecond) > wait_until do
      :timeout
    else
      if condition.() do
        :ok
      else
        Process.sleep(10)
        do_wait_for(condition, wait_until)
      end
    end
  end
end